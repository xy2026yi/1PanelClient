//
//  ContainerComposesView.swift
//  1PanelClient
//
//  编排管理（logs/推荐实现-容器.md 抓包 2026-09-14）：
//  列表（容器运行态/环境变量）· 详情（启停/重启/重建/删除 · 配置/编辑/日志/备份）
//  · 创建（编辑/路径/模板三种来源，test→create 两段提交）· 编排模板 CRUD
//

import SwiftUI

// MARK: - 编排列表

struct ContainerComposesView: View {
    let server: ServerConfig

    @State private var composes: [ContainerCompose] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showCreate = false
    @State private var showTemplates = false
    @State private var toastMessage: String?
    /// 创建编排任务进度（由创建 Sheet 回调后从列表页 push，确保可见）
    @State private var progressTask: ComposeTaskTarget?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let err = loadError {
                LoadErrorStateView(message: err) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else if composes.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无编排"),
                    systemImage: "square.stack.3d.up.fill",
                    description: Text(L10n.t("点击右上角 + 创建编排")))
                .listRowBackground(Color.clear)
            } else {
                ForEach(composes) { compose in
                    NavigationLink {
                        ContainerComposeDetailView(server: server, compose: compose) {
                            Task { await load() }
                        }
                    } label: {
                        composeRow(compose)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("编排"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTemplates = true
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel(L10n.t("编排模板"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建编排"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toastMessage)
        // 创建编排改为 push（返回即取消；表单带 push 模式参数）
        .navigationDestination(isPresented: $showCreate) {
            ContainerComposeCreateView(server: server, presentedAsSheet: false) { name, taskID in
                toastMessage = L10n.f("创建编排 %@ 已提交", name)
                progressTask = ComposeTaskTarget(
                    taskID: taskID, title: L10n.f("创建编排 %@", name))
                Task { await load() }
            }
        }
        .navigationDestination(item: $progressTask) { target in
            TaskProgressView(taskID: target.taskID, title: target.title) { isDone in
                if isDone { Task { await load() } }
                return false
            }
        }
        .navigationDestination(isPresented: $showTemplates) {
            ContainerTemplatesView(server: server)
        }
    }

    private func composeRow(_ compose: ContainerCompose) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(compose.name).font(.body.weight(.medium))
                Spacer()
                HStack(spacing: 4) {
                    StatusDot(color: (compose.runningCount ?? 0) > 0 ? .green : .secondary, diameter: 8)
                    Text(L10n.f("%ld/%ld 运行", compose.runningCount ?? 0, compose.containerCount ?? 0))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                if let createdBy = compose.createdBy, !createdBy.isEmpty {
                    Text(L10n.t("来源") + " " + createdBy)
                }
                if let createdAt = compose.createdAt, !createdAt.isEmpty {
                    Text(createdAt)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do {
            let resp: PageResponse<ContainerCompose> = try await client.send(
                path: APIEndpoint.containersComposeSearch.path,
                body: ContainerComposeSearchRequest(page: 1, pageSize: 100),
                as: PageResponse<ContainerCompose>.self)
            composes = resp.items ?? []
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - 编排详情

struct ContainerComposeDetailView: View {
    let server: ServerConfig
    /// 列表快照（页面内操作后经 onReload 重拉列表）
    @State private var compose: ContainerCompose
    let onReload: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var pendingOperate: String?
    @State private var isOperating = false
    /// 操作抽屉展开状态（与容器详情一致的下拉抽屉）
    @State private var isStatusExpanded = false
    @State private var showLog = false
    @State private var showEdit = false
    @State private var showBackup = false
    /// 工作目录跳文件管理的目标路径
    @State private var workdirTarget: String?
    @State private var showDeleteSheet = false
    @State private var deleteWithFile = false
    @State private var deleteForce = false

    private let client: APIClient

    init(server: ServerConfig, compose: ContainerCompose, onReload: @escaping () -> Void) {
        self.server = server
        _compose = State(initialValue: compose)
        self.onReload = onReload
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            operateSection
            infoSection
            containersSection
            envSection
            navSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(compose.name)
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay(message: $toastMessage)
        .modifier(ComposeDetailDialogsModifier(
            showError: $showError,
            errorMessage: $errorMessage,
            pendingOperate: $pendingOperate,
            showDeleteSheet: $showDeleteSheet,
            deleteWithFile: $deleteWithFile,
            deleteForce: $deleteForce,
            showEdit: $showEdit,
            showLog: $showLog,
            showBackup: $showBackup,
            compose: compose,
            client: client,
            server: server,
            onOperate: { op, withFile, force in Task { await operate(op, withFile: withFile, force: force) } },
            onEditSaved: {
                onReload()
                Task { await reloadSelf() }
            }))
        // 工作目录跳文件管理并打开该路径
        .navigationDestination(item: $workdirTarget) { path in
            FilesView(server: server, initialPath: path)
        }
    }

    /// 有容器在运行即视为运行中（决定启停按钮形态）
    private var isRunning: Bool { (compose.runningCount ?? 0) > 0 }

    /// 操作抽屉：头部 + 展开区行式按钮（每行 4 个，与容器详情状态抽屉同构）
    private var operateSection: some View {
        Section {
            operateHeader
            if isStatusExpanded {
                operationsRow1
                    .padding(.top, 4)
                operationsRow2
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
        }
    }

    /// 抽屉头部：名称 + 运行态 + 展开箭头（与容器详情状态抽屉同构）
    private var operateHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(compose.name).font(.body.bold()).lineLimit(1)
                Text(L10n.f("%ld/%ld 运行", compose.runningCount ?? 0, compose.containerCount ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                StatusDot(color: isRunning ? .green : .secondary)
                Text(isRunning ? L10n.t("运行中") : L10n.t("已停止"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                withAnimation(Motion.standard) {
                    isStatusExpanded.toggle()
                }
            } label: {
                Image(systemName: isStatusExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(isOperating)
        }
        .padding(.vertical, 2)
    }

    /// 第一行：启停 / 重启 / 重建 / 删除（按运行态隐藏无效操作）
    private var operationsRow1: some View {
        HStack(spacing: 8) {
            if !isRunning {
                operateButton("up", title: L10n.t("启动"), icon: "play.fill", color: .green)
            } else {
                operateButton("stop", title: L10n.t("停止"), icon: "stop.fill", color: .orange)
            }
            operateButton("restart", title: L10n.t("重启"), icon: "arrow.triangle.2.circlepath", color: .blue)
            operateButton("rebuild", title: L10n.t("重建"), icon: "arrow.triangle.2.circlepath.camera", color: .purple)
            operateButton("delete", title: L10n.t("删除"), icon: "trash", color: .red)
        }
    }

    /// 第二行：编辑 / 备份（与容器详情「编辑」同款抽屉按钮形态）
    private var operationsRow2: some View {
        HStack(spacing: 8) {
            operateButton("edit", title: L10n.t("编辑"), icon: "pencil", color: .cyan)
            operateButton("backup", title: L10n.t("备份"), icon: "externaldrive.badge.timemachine", color: .brown)
        }
    }

    private var infoSection: some View {
        Section {
            InfoRow(L10n.t("名称"), value: compose.name)
            if let createdBy = compose.createdBy, !createdBy.isEmpty {
                InfoRow(L10n.t("来源"), value: createdBy)
            }
            if let createdAt = compose.createdAt, !createdAt.isEmpty {
                InfoRow(L10n.t("创建时间"), value: createdAt)
            }
            if let workdir = compose.workdir, !workdir.isEmpty {
                // 点击跳文件管理并打开该路径（复制入口移除）
                Button {
                    workdirTarget = workdir
                } label: {
                    HStack {
                        Text(L10n.t("工作目录"))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Spacer(minLength: 12)
                        Text(workdir)
                            .font(.dataMonospacedCaption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .truncationMode(.head)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            SectionLabel(title: L10n.t("基本信息"), systemImage: "info.circle")
        }
    }

    @ViewBuilder private var containersSection: some View {
        if let containers = compose.containers, !containers.isEmpty {
            Section {
                ForEach(containers) { c in
                    containerRow(c)
                }
            } header: {
                SectionLabel(
                    title: L10n.f("容器（%ld）", containers.count),
                    systemImage: "shippingbox")
            }
        }
    }

    private func containerRow(_ c: ContainerComposeItem) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: (c.state ?? "").lowercased() == "running" ? .green : .secondary, diameter: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name ?? String(c.containerID.prefix(12)))
                    .font(.subheadline.weight(.medium))
                if let ports = c.ports, !ports.isEmpty {
                    Text(ports.joined(separator: ", "))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(c.state ?? "-")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var envSection: some View {
        if let env = compose.env, !env.isEmpty {
            Section {
                Text(env)
                    .font(.dataMonospacedCaption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                SectionLabel(title: L10n.t("环境变量"), systemImage: "gearshape.2")
            }
        }
    }

    /// 日志入口（配置/编辑/备份已移入或移出：配置查看移除，编辑/备份在状态抽屉）
    private var navSection: some View {
        Section {
            navLink(L10n.t("日志"), icon: "doc.text") { showLog = true }
        } header: {
            SectionLabel(title: L10n.t("日志"), systemImage: "doc.text")
        }
    }

    private func navLink(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func operateButton(_ op: String, title: String, icon: String, color: Color) -> some View {
        CardActionButton(
            title: title, icon: icon, color: color,
            busy: isOperating, disabled: isOperating) {
            switch op {
            case "delete":
                deleteWithFile = false
                deleteForce = false
                showDeleteSheet = true
            case "edit":
                showEdit = true
            case "backup":
                showBackup = true
            default:
                pendingOperate = op
            }
        }
    }

    static func operateName(_ op: String) -> String {
        switch op {
        case "up": return L10n.t("启动")
        case "stop": return L10n.t("停止")
        case "restart": return L10n.t("重启")
        case "rebuild": return L10n.t("重建")
        case "delete": return L10n.t("删除")
        default: return op
        }
    }

    private func operate(_ op: String, withFile: Bool = false, force: Bool = false) async {
        isOperating = true
        defer { isOperating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersComposeOperate.path,
                body: ContainerComposeOperateRequest(
                    name: compose.name, path: compose.path ?? "",
                    operation: op, withFile: withFile, force: force),
                as: EmptyResponse.self)
            if op == "delete" {
                toastMessage = L10n.f("已删除「%@」", compose.name)
                onReload()
                // 分步收栈：等 toast 展示后返回列表
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() }
            } else {
                toastMessage = L10n.t("操作成功")
                await reloadSelf()
                onReload()
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 后端无单条查询：重拉列表后按名称匹配刷新本页快照
    private func reloadSelf() async {
        if let resp: PageResponse<ContainerCompose> = try? await client.send(
            path: APIEndpoint.containersComposeSearch.path,
            body: ContainerComposeSearchRequest(page: 1, pageSize: 100),
            as: PageResponse<ContainerCompose>.self),
           let matched = (resp.items ?? []).first(where: { $0.name == compose.name }) {
            compose = matched
        }
    }
}

// MARK: - 详情弹窗/跳转集合（拆离 body 以控制类型推断负担）

private struct ComposeDetailDialogsModifier: ViewModifier {
    @Binding var showError: Bool
    @Binding var errorMessage: String?
    @Binding var pendingOperate: String?
    @Binding var showDeleteSheet: Bool
    @Binding var deleteWithFile: Bool
    @Binding var deleteForce: Bool
    @Binding var showEdit: Bool
    @Binding var showLog: Bool
    @Binding var showBackup: Bool
    let compose: ContainerCompose
    let client: APIClient
    let server: ServerConfig
    let onOperate: (String, Bool, Bool) -> Void
    let onEditSaved: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert(
                pendingOperate.map { ContainerComposeDetailView.operateName($0) } ?? "",
                isPresented: Binding(
                    get: { pendingOperate != nil },
                    set: { if !$0 { pendingOperate = nil } }
                )
            ) {
                Button(L10n.t("取消"), role: .cancel) { pendingOperate = nil }
                Button(L10n.t("确认"), role: .destructive) {
                    Haptic.warning()
                    let op = pendingOperate
                    pendingOperate = nil
                    if let op { onOperate(op, false, false) }
                }
            } message: {
                Text(L10n.f(
                    "将对编排「%@」进行 %@ 操作，是否继续？",
                    compose.name,
                    ContainerComposeDetailView.operateName(pendingOperate ?? "")))
            }
            .sheet(isPresented: $showDeleteSheet) {
                TextInputConfirmSheet(
                    title: L10n.t("删除编排"),
                    message: L10n.f("删除操作无法回滚，请输入 \"%@\" 删除此编排", compose.name),
                    expectedText: compose.name,
                    onConfirm: {
                        onOperate("delete", deleteWithFile, deleteForce)
                    },
                    options: {
                        Section(L10n.t("选项")) {
                            Toggle(L10n.t("删除文件"), isOn: $deleteWithFile)
                            Toggle(L10n.t("强制删除"), isOn: $deleteForce)
                        }
                    }
                )
            }
            .navigationDestination(isPresented: $showEdit) {
                ContainerComposeEditView(server: server, compose: compose, onUpdated: onEditSaved)
            }
            .navigationDestination(isPresented: $showLog) {
                ComposeLogView(
                    title: L10n.f("日志 · %@", compose.name),
                    composePath: compose.path ?? "",
                    client: client)
            }
            .navigationDestination(isPresented: $showBackup) {
                BackupListView(target: BackupTarget(
                    type: "compose", name: compose.name, detailName: ""))
            }
    }
}

// MARK: - 编辑（更新）

struct ContainerComposeEditView: View {
    let server: ServerConfig
    let compose: ContainerCompose
    let onUpdated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var envText = ""
    @State private var forcePull = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var progressTaskID: String?

    private let client: APIClient

    init(server: ServerConfig, compose: ContainerCompose, onUpdated: @escaping () -> Void) {
        self.server = server
        self.compose = compose
        self.onUpdated = onUpdated
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        Form {
            Section {
                OutlinedMultiLineField(label: "docker-compose.yml",
                                       lines: 12, fixedLines: 12,
                                       zoomable: true, monospaced: true,
                                       text: $content)
            } header: {
                SectionLabel(title: "docker-compose.yml", systemImage: "doc.text")
            }
            Section {
                OutlinedMultiLineField(label: L10n.t("环境变量"), prompt: "KEY=VALUE",
                                       text: $envText)
            } header: {
                SectionLabel(title: L10n.t("环境变量"), systemImage: "gearshape.2")
            } footer: {
                Text(L10n.t("一行一个，格式 key=value"))
            }
            Section {
                Toggle(L10n.t("强制拉取镜像"), isOn: $forcePull)
            }
        }
        .navigationTitle(L10n.t("编辑编排"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("保存")) {
                    Task { await submit() }
                }
                .disabled(isSubmitting || content.isEmpty)
            }
        }
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await loadContent() }
        .navigationDestination(item: Binding(
            get: { progressTaskID.map { ComposeTaskTarget(taskID: $0, title: L10n.f("更新编排 %@", compose.name)) } },
            set: { if $0 == nil { progressTaskID = nil } }
        )) { target in
            TaskProgressView(taskID: target.taskID, title: target.title) { isDone in
                if isDone {
                    onUpdated()
                    Task { try? await Task.sleep(for: .milliseconds(350)); dismiss() }
                }
                return false
            }
        }
    }

    private func loadContent() async {
        if let text: String = try? await client.send(
            path: APIEndpoint.containersInspect.path,
            body: ContainerInspectRequest(
                id: compose.name, type: "compose", detail: compose.path ?? ""),
            as: String.self) {
            content = text
        }
        // 列表返回的 env 为 "K='V'\n" 形态，直接回填编辑器
        envText = compose.env ?? ""
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let taskID = UUID().uuidString
        let req = ContainerComposeUpdateRequest(
            taskID: taskID,
            name: compose.name,
            path: compose.path ?? "",
            detailPath: compose.path ?? "",
            content: content,
            createdBy: compose.createdBy ?? "1Panel",
            env: envText,
            forcePull: forcePull)
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersComposeUpdate.path, body: req, as: EmptyResponse.self)
            progressTaskID = taskID
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

/// 编排任务目标（创建/更新共用：taskID → 任务进度页）
struct ComposeTaskTarget: Identifiable, Hashable {
    let taskID: String
    let title: String
    var id: String { taskID }
}

// MARK: - 创建编排（编辑 / 路径 / 模板 三来源）

struct ContainerComposeCreateView: View {
    let server: ServerConfig
    /// 提交成功回调（名称 + taskID；进度页由列表页 push，避免 Sheet 内嵌跳转不生效）
    let onCreated: (String, String) -> Void
    /// true = 以 sheet 弹出（自带 NavigationStack + 取消按钮）；false = 页面推入（返回即取消）
    var presentedAsSheet: Bool = true

    @Environment(\.dismiss) private var dismiss
    /// edit / path / template
    @State private var from = "edit"
    @State private var dirName = ""
    @State private var pathText = ""
    /// path 来源：名称是否被手动编辑过（未编辑时随路径自动带出目录名）
    @State private var nameManuallyEdited = false
    @State private var file = ""
    /// 环境变量多行原文（每行一条 KEY=VALUE，形态 7.1）
    @State private var envText = ""
    @State private var forcePull = false
    @State private var templates: [ContainerTemplate] = []
    @State private var selectedTemplate: Int?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, presentedAsSheet: Bool = true,
         onCreated: @escaping (String, String) -> Void) {
        self.server = server
        self.presentedAsSheet = presentedAsSheet
        self.onCreated = onCreated
        self.client = APIClient.shared(for: server)
    }

    private var nameValue: String {
        // 抓包 2026-09-15：path 来源 name 为独立输入的名称（如 alpine-1）、
        // dirName 恒空；name 须符 ^[a-z0-9][a-z0-9_-]{0,255}$
        dirName.trimmingCharacters(in: .whitespaces)
    }

    private var canSubmit: Bool {
        switch from {
        case "path":
            let p = pathText.trimmingCharacters(in: .whitespaces)
            // path 必须是完整 compose 文件路径（抓包：.../xxx/docker-compose.yml）；
            // .yml / .yaml 均合法；名称必填
            return !p.isEmpty && (p.hasSuffix(".yml") || p.hasSuffix(".yaml"))
                && !dirName.trimmingCharacters(in: .whitespaces).isEmpty
        case "template":
            return !dirName.trimmingCharacters(in: .whitespaces).isEmpty && selectedTemplate != nil
        default:
            return !dirName.trimmingCharacters(in: .whitespaces).isEmpty && !file.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        Group {
            if presentedAsSheet {
                NavigationStack {
                    form
                }
                .presentationDragIndicator(.visible)
                .bottomSheetDetents([.large])
                .interactiveDismissDisabled(isSubmitting)
            } else {
                form
                    // 提交中禁止侧滑返回：失败 alert 挂在本页，被 pop 后错误会被吞
                    .navigationBarBackButtonHidden(isSubmitting)
            }
        }
    }

    private var form: some View {
        Form {
                Section {
                    OutlinedPicker(label: L10n.t("来源"),
                                   options: ["edit", "path", "template"],
                                   selection: $from,
                                   optionLabels: ["edit": L10n.t("编辑"),
                                                  "path": L10n.t("路径"),
                                                  "template": L10n.t("编排模板")])

                    if from == "template" {
                        OutlinedPicker(label: L10n.t("模板"),
                                       options: templateOptionKeys, selection: templateText,
                                       optionLabels: templateOptionLabels)
                            .onChange(of: selectedTemplate) { _, newValue in
                                // 选中模板即把内容带入编辑器（网页端行为）
                                if let id = newValue,
                                   let t = templates.first(where: { $0.id == id }) {
                                    file = t.content ?? ""
                                }
                            }
                    }
                    if from == "path" {
                        // 路径必须选到 compose 文件（抓包：完整 docker-compose.yml 路径）
                        FilePathBrowseRow(
                            title: L10n.t("路径"), path: $pathText, client: client,
                            fileExtensions: ["yml", "yaml"])
                    }
                    OutlinedTextField(label: L10n.t("名称"), text: $dirName)
                        .onChange(of: dirName) { old, new in
                            // 区分用户编辑与自动带出：手动改动后不再跟随路径
                            if !new.isEmpty && new != old { nameManuallyEdited = true }
                        }
                        .onChange(of: pathText) { _, newPath in
                            guard !nameManuallyEdited else { return }
                            // 未手动命名时随路径自动带出所在目录名（网页端行为）
                            let dir = (newPath.trimmingCharacters(in: .whitespaces) as NSString).deletingLastPathComponent
                            dirName = dir.split(separator: "/").last.map(String.init) ?? dirName
                        }
                } header: {
                    SectionLabel(title: L10n.t("基本信息"), systemImage: "square.stack.3d.up")
                } footer: {
                    if from == "path" {
                        Text(L10n.t("路径需选择到 docker-compose.yml 文件；名称默认取文件所在目录名，可修改。"))
                    } else {
                        Text(L10n.t("编排文件保存路径：/opt/1panel/docker/compose/名称；若 Docker Compose 中指定了项目名称，则优先使用该名称。"))
                    }
                }

                if from != "path" {
                    Section {
                        OutlinedMultiLineField(label: "docker-compose.yml",
                                               lines: 10, fixedLines: 10,
                                               zoomable: true, monospaced: true,
                                               text: $file)
                    } header: {
                        SectionLabel(title: "docker-compose.yml", systemImage: "doc.text")
                    }
                }

                Section {
                    OutlinedMultiLineField(label: L10n.t("环境变量"), prompt: "KEY=VALUE",
                                           text: $envText)
                }
                Section {
                    Toggle(L10n.t("强制拉取镜像"), isOn: $forcePull)
                }
            }
            .navigationTitle(L10n.t("创建编排"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if presentedAsSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("取消")) { dismiss() }
                            .disabled(isSubmitting)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("创建")) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await loadTemplates() }
    }

    private func loadTemplates() async {
        if let resp: PageResponse<ContainerTemplate> = try? await client.send(
            path: APIEndpoint.containersTemplateSearch.path,
            body: ContainerPageRequest(page: 1, pageSize: 100),
            as: PageResponse<ContainerTemplate>.self) {
            templates = resp.items ?? []
        }
    }

    /// 模板选项（OutlinedPicker 用 String 键；0=请选择）
    private var templateOptionKeys: [String] {
        ["0"] + templates.map { String($0.id) }
    }

    private var templateOptionLabels: [String: String] {
        var labels = ["0": L10n.t("请选择")]
        for t in templates { labels[String(t.id)] = t.name ?? "#\(t.id)" }
        return labels
    }

    private var templateText: Binding<String> {
        Binding<String>(
            get: { selectedTemplate.map(String.init) ?? "0" },
            set: { selectedTemplate = $0 == "0" ? nil : Int($0) }
        )
    }

    /// 两段提交：compose/test 校验通过（data=true）后才真正提交 compose
    private func submit() async {
        isSubmitting = true
        // 成功路径交由延迟收栈回调复位；其余路径 defer 兜底
        var progressHandoff = false
        defer { if !progressHandoff { isSubmitting = false } }
        let name = nameValue
        let dirNameValue = from == "path" ? "" : dirName.trimmingCharacters(in: .whitespaces)
        let nameField = from == "path" ? name : ""
        let testReq = ContainerComposeUpsertRequest(
            dirName: dirNameValue, from: from,
            path: from == "path" ? pathText.trimmingCharacters(in: .whitespaces) : "",
            file: from == "path" ? "" : file,
            template: from == "template" ? selectedTemplate : nil,
            env: envText,
            forcePull: forcePull)
        // 抓包：test 请求同样携带 name（path 来源为名称输入框的值）
        var testReqNamed = testReq
        testReqNamed.name = nameField
        do {
            let testOK: Bool = try await client.send(
                path: APIEndpoint.containersComposeTest.path, body: testReqNamed, as: Bool.self)
            guard testOK else {
                errorMessage = L10n.t("校验未通过，请检查编排内容")
                showError = true
                return
            }
            var createReq = testReqNamed
            let taskID = UUID().uuidString
            createReq.taskID = taskID
            createReq.name = nameField
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersComposeCreate.path, body: createReq, as: EmptyResponse.self)
            // 提交成功即交回列表页（由其 push 任务进度并刷新）。同帧「pop 自己 +
            // 父页 push 进度页」会被导航合并丢弃其一（同文件 440/612 行的分步
            // 收栈即为避开此问题）：先让父页完成 push，再延迟收栈；期间保持
            // isSubmitting 防重复提交
            progressHandoff = true
            onCreated(name, taskID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                dismiss()
                isSubmitting = false
            }
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 编排模板管理

struct ContainerTemplatesView: View {
    let server: ServerConfig

    @State private var templates: [ContainerTemplate] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showCreate = false
    @State private var editingTemplate: ContainerTemplate?
    @State private var toastMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var pendingDelete: ContainerTemplate?

    private let client: APIClient

    init(server: ServerConfig) {
        self.server = server
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let err = loadError {
                LoadErrorStateView(message: err) {
                    Task { await load() }
                }
                .listRowBackground(Color.clear)
            } else if templates.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无编排模板"),
                    systemImage: "doc.on.doc",
                    description: Text(L10n.t("点击右上角 + 创建模板")))
                .listRowBackground(Color.clear)
            } else {
                ForEach(templates) { template in
                    Button {
                        editingTemplate = template
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(template.name ?? "#\(template.id)")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            if let desc = template.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = template
                        } label: {
                            Label(L10n.t("删除"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("编排模板"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建模板"))
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .toastOverlay(message: $toastMessage)
        .alert(L10n.t("提示"), isPresented: $showError) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L10n.t("删除模板"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L10n.t("取消"), role: .cancel) { pendingDelete = nil }
            Button(L10n.t("删除"), role: .destructive) {
                if let template = pendingDelete {
                    Task { await delete(template) }
                }
            }
        } message: {
            Text(L10n.f("确定删除模板「%@」吗？", pendingDelete?.name ?? ""))
        }
        // 模板新建/编辑改为 push（返回即取消；表单带 push 模式参数）
        .navigationDestination(isPresented: $showCreate) {
            ContainerTemplateEditSheet(server: server, template: nil,
                                       presentedAsSheet: false) {
                Task { await load() }
            }
        }
        .navigationDestination(item: $editingTemplate) { template in
            ContainerTemplateEditSheet(server: server, template: template,
                                       presentedAsSheet: false) {
                Task { await load() }
            }
        }
    }

    private func load() async {
        do {
            let resp: PageResponse<ContainerTemplate> = try await client.send(
                path: APIEndpoint.containersTemplateSearch.path,
                body: ContainerPageRequest(page: 1, pageSize: 100),
                as: PageResponse<ContainerTemplate>.self)
            templates = resp.items ?? []
            loadError = nil
        } catch {
            guard !APIError.isCancellation(error) else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func delete(_ template: ContainerTemplate) async {
        pendingDelete = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.containersTemplateDelete.path,
                body: ContainerTemplateDeleteRequest(ids: [template.id]),
                as: EmptyResponse.self)
            toastMessage = L10n.f("已删除「%@」", template.name ?? "#\(template.id)")
            await load()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - 模板创建/编辑 Sheet（编辑时名称不可改，抓包确认）

private struct ContainerTemplateEditSheet: View {
    let server: ServerConfig
    /// nil = 创建
    let template: ContainerTemplate?
    /// true = 以 sheet 弹出（自带 NavigationStack + 取消按钮）；false = 页面推入（返回即取消）
    var presentedAsSheet: Bool = true
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var descriptionText = ""
    @State private var content = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, template: ContainerTemplate?,
         presentedAsSheet: Bool = true, onSaved: @escaping () async -> Void) {
        self.server = server
        self.template = template
        self.presentedAsSheet = presentedAsSheet
        self.onSaved = onSaved
        self.client = APIClient.shared(for: server)
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Group {
            if presentedAsSheet {
                NavigationStack {
                    form
                }
                .presentationDragIndicator(.visible)
                .bottomSheetDetents([.large])
                .interactiveDismissDisabled(isSubmitting)
            } else {
                form
                    // 提交中禁止侧滑返回：失败 alert 挂在本页，被 pop 后错误会被吞
                    .navigationBarBackButtonHidden(isSubmitting)
            }
        }
    }

    private var form: some View {
        Form {
                Section {
                    OutlinedTextField(label: L10n.t("名称"), text: $name,
                                      disabled: template != nil)
                } header: {
                    SectionLabel(title: L10n.t("基本信息"), systemImage: "doc.on.doc")
                }
                Section {
                    OutlinedMultiLineField(label: "docker-compose.yml",
                                           lines: 10, fixedLines: 10,
                                           zoomable: true, monospaced: true,
                                           text: $content)
                } header: {
                    SectionLabel(title: "docker-compose.yml", systemImage: "doc.text")
                }
                // 描述置底（形态 7.1，默认 1 行自动增高）
                Section {
                    OutlinedMultiLineField(label: L10n.t("描述"), prompt: L10n.t("可选"),
                                           lines: 1, text: $descriptionText)
                }
            }
            .navigationTitle(template == nil ? L10n.t("创建模板") : L10n.t("编辑模板"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if presentedAsSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("取消")) { dismiss() }
                            .disabled(isSubmitting)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if let template {
                    name = template.name ?? ""
                    descriptionText = template.description ?? ""
                    content = template.content ?? ""
                }
            }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            if let template {
                // 编辑全字段回传（createdAt 原值，抓包确认）
                let req = ContainerTemplateUpdateRequest(
                    id: template.id,
                    createdAt: template.createdAt ?? "",
                    name: name.trimmingCharacters(in: .whitespaces),
                    description: descriptionText,
                    content: content)
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.containersTemplateUpdate.path, body: req, as: EmptyResponse.self)
            } else {
                let req = ContainerTemplateCreateRequest(
                    name: name.trimmingCharacters(in: .whitespaces),
                    content: content,
                    description: descriptionText)
                let _: EmptyResponse = try await client.send(
                    path: APIEndpoint.containersTemplateCreate.path, body: req, as: EmptyResponse.self)
            }
            await onSaved()
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
