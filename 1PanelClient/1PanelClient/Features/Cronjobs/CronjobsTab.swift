//
//  CronjobsTab.swift
//  1PanelClient
//
//  计划任务：列表 / 详情 / 创建 / 手动执行 / 删除 / 执行记录 / 日志
//  基于 doc/计划任务.md
//

import SwiftUI
import Combine

struct CronjobsTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: CronjobsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCreateSheet = false

    /// 是否显示关闭按钮（fullScreen 模式用 true，作为分段/嵌入内容时用 false）
    var showCloseButton: Bool = true
    /// true=自带 NavigationStack（独立/fullScreen 用）；false=仅提供内容（嵌入外层栈）
    var standalone: Bool = true

    init(manager: ServerManager, showCloseButton: Bool = true, standalone: Bool = true) {
        self.manager = manager
        self.showCloseButton = showCloseButton
        self.standalone = standalone
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: CronjobsViewModel(server: server))
    }

    var body: some View {
        if standalone {
            NavigationStack {
                rootContent
            }
            .task { await vm.refresh() }
            .alert(vm.alertMessage, isPresented: $vm.showAlert) {
                Button("好", role: .cancel) {}
            }
            .toastOverlay(message: $vm.toastMessage)
        } else {
            rootContent
                .task { await vm.refresh() }
                .alert(vm.alertMessage, isPresented: $vm.showAlert) {
                    Button("好", role: .cancel) {}
                }
                .toastOverlay(message: $vm.toastMessage)
        }
    }

    /// 列表根内容（不含 NavigationStack），供 ManageTab 嵌入复用
    var rootContent: some View {
        Group {
            if vm.isLoading && vm.cronjobs.isEmpty {
                ProgressView("加载中…")
            } else if vm.cronjobs.isEmpty {
                ContentUnavailableView(
                    "暂无计划任务",
                    systemImage: "clock.badge.checkmark",
                    description: Text(vm.errorMessage ?? "点击右上角创建第一个任务")
                )
            } else {
                cronjobList
            }
        }
        .navigationTitle("计划任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ScriptLibraryView(server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
                } label: {
                    Image(systemName: "books.vertical")
                }
                .accessibilityLabel("脚本库")
            }
        }
        .navigationDestination(for: Cronjob.self) { job in
            CronjobDetailView(job: job, vm: vm, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                showCreateSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 4)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 20)
            .accessibilityLabel("创建计划任务")
        }
        .navigationDestination(isPresented: $showCreateSheet) {
            CreateCronjobView(vm: vm, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
    }

    private var cronjobList: some View {
        List {
            ForEach(vm.cronjobs) { job in
                NavigationLink(value: job) {
                    CronjobRow(job: job)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        Task { await vm.handle(job: job) }
                    } label: {
                        Label("执行", systemImage: "play.fill")
                    }
                    .tint(.blue)

                    Button(role: .destructive) {
                        vm.pendingDeleteJob = job
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh()
        }
        .alert("删除任务", isPresented: Binding(
            get: { vm.pendingDeleteJob != nil },
            set: { if !$0 { vm.pendingDeleteJob = nil } }
        )) {
            Button("取消", role: .cancel) {
                vm.pendingDeleteJob = nil
                vm.deleteCleanData = false
            }
            Button("删除", role: .destructive) {
                if let job = vm.pendingDeleteJob {
                    Task { await vm.delete(job: job) }
                }
            }
        } message: {
            VStack {
                Text("确定删除任务「\(vm.pendingDeleteJob?.name ?? "")」吗？")
                Toggle("同时删除备份文件", isOn: $vm.deleteCleanData)
            }
        }
    }
}

// MARK: - 任务列表项

struct CronjobRow: View {
    let job: Cronjob

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: job.jobType.icon, color: job.jobType.color)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.name ?? "未命名")
                    .font(.body.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusBadge(text: job.jobType.displayName, color: job.jobType.color, backgroundOpacity: 0.12)
                    StatusBadge(text: job.specDisplay, color: .secondary, backgroundOpacity: 0.1)
                }

                if let last = job.lastRecordStatus, !last.isEmpty {
                    Text("上次：\(job.lastStatusDisplay)")
                        .font(.caption2)
                        .foregroundStyle(job.lastStatusColor)
                }
            }

            Spacer()

            // 启用/禁用徽标
            if !job.isEnabled {
                StatusBadge(text: "已停用", color: .secondary, backgroundOpacity: 0.1)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 任务详情

struct CronjobDetailView: View {
    let job: Cronjob
    @ObservedObject var vm: CronjobsViewModel
    var server: ServerConfig = ServerConfig(name: "", baseURL: "", apiKey: "")
    @Environment(\.dismiss) private var dismiss
    @State private var editingInfo: CronjobInfo?
    @State private var showEditView = false
    @State private var isLoadingEditInfo = false

    /// 从 ViewModel 列表中查找最新的任务数据。
    /// 编辑后 vm.cronjobs 会刷新，此属性返回更新后的版本；
    /// 如果列表中已无此任务（被删除），则回退到原始 job。
    private var currentJob: Cronjob {
        vm.cronjobs.first(where: { $0.id == job.id }) ?? job
    }

    var body: some View {
        List {
            Section("基本信息") {
                LabeledRow("名称", value: currentJob.name ?? "—")
                LabeledRow("类型", value: currentJob.jobType.displayName)
                LabeledRow("执行周期", value: currentJob.specDisplay)
                LabeledRow("状态", value: currentJob.isEnabled ? "启用" : "停用")
                LabeledRow("保留份数", value: currentJob.retainCopiesDisplay)
                if let r = currentJob.retryTimes, r > 0 {
                    LabeledRow("重试次数", value: "\(r) 次")
                }
                if let t = currentJob.timeout, t > 0 {
                    LabeledRow("超时", value: "\(t)\(currentJob.timeoutUnit ?? "s")")
                }
            }

            // 类型相关详情
            switch currentJob.jobType {
            case .shell:
                if let user = currentJob.user, !user.isEmpty {
                    Section("执行设置") {
                        LabeledRow("执行用户", value: user)
                        if currentJob.inContainer == true {
                            LabeledRow("容器", value: currentJob.containerName ?? "—")
                        }
                    }
                }
                if let script = currentJob.script, !script.isEmpty {
                    Section {
                        Text(script)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } header: { Text("脚本内容") }
                }
            case .app:
                Section("备份内容") {
                    LabeledRow("备份对象", value: currentJob.appID == "all" ? "全部应用" : (currentJob.appID ?? "—"))
                }
            case .website:
                Section("备份内容") {
                    LabeledRow("备份对象", value: currentJob.website == "all" ? "全部网站" : (currentJob.website ?? "—"))
                }
            case .database:
                Section("备份内容") {
                    LabeledRow("数据库类型", value: currentJob.dbTypeDisplay)
                    LabeledRow("备份对象", value: currentJob.dbName == "all" ? "全部数据库" : (currentJob.dbName ?? "—"))
                    if currentJob.dbTypeDisplay == "MySQL" || currentJob.dbTypeDisplay == "MariaDB" {
                        LabeledRow("备份参数", value: currentJob.dbBackupParamsDisplay)
                    }
                }
            case .snapshot:
                Section("备份内容") {
                    LabeledRow("类型", value: "系统快照")
                }
            }

            // 操作
            Section {
                Button {
                    Task { await vm.handle(job: currentJob) }
                } label: {
                    Label("立即执行", systemImage: "play.fill")
                }
                NavigationLink {
                    CronjobRecordsView(job: currentJob, vm: vm)
                } label: {
                    Label("执行记录", systemImage: "list.bullet.rectangle")
                }
                Button {
                    Task { await loadEditInfo() }
                } label: {
                    HStack {
                        Label("编辑任务", systemImage: "pencil")
                        if isLoadingEditInfo {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
            }

            // 危险操作
            Section {
                Button(role: .destructive) {
                    vm.pendingDeleteJob = currentJob
                } label: {
                    Label("删除任务", systemImage: "trash")
                }
            } header: {
                Text("危险操作")
            } footer: {
                Text("删除后不可恢复，可选择是否同时删除已生成的备份文件")
            }
        }
        .navigationTitle(currentJob.name ?? "任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除任务", isPresented: Binding(
            get: { vm.pendingDeleteJob != nil },
            set: { if !$0 { vm.pendingDeleteJob = nil } }
        )) {
            Button("取消", role: .cancel) {
                vm.pendingDeleteJob = nil
                vm.deleteCleanData = false
            }
            Button("删除", role: .destructive) {
                if let j = vm.pendingDeleteJob {
                    Task {
                        let success = await vm.delete(job: j)
                        if success {
                            dismiss()
                        }
                    }
                }
            }
        } message: {
            VStack {
                Text("确定删除任务「\(vm.pendingDeleteJob?.name ?? "")」吗？")
                Toggle("同时删除备份文件", isOn: $vm.deleteCleanData)
            }
        }
        .toastOverlay(message: $vm.toastMessage)
        .navigationDestination(isPresented: $showEditView) {
            if let info = editingInfo {
                CreateCronjobView(vm: vm, server: server, editingJob: info)
            }
        }
    }

    /// 加载编辑所需的任务详情，加载成功后跳转到编辑表单
    private func loadEditInfo() async {
        isLoadingEditInfo = true
        let info = await vm.loadCronjobInfo(id: job.id)
        isLoadingEditInfo = false
        if let info = info {
            editingInfo = info
            showEditView = true
        }
    }
}

// MARK: - 执行记录

struct CronjobRecordsView: View {
    let job: Cronjob
    @ObservedObject var vm: CronjobsViewModel
    @State private var selectedRecord: CronjobRecord?

    var body: some View {
        List {
            if vm.isLoadingRecords && vm.records.isEmpty {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else if vm.records.isEmpty {
                ContentUnavailableView(
                    "暂无执行记录",
                    systemImage: "list.bullet.rectangle",
                    description: Text("点击任务详情中的「立即执行」生成第一条记录")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(vm.records) { record in
                    Button {
                        selectedRecord = record
                    } label: {
                        CronjobRecordRow(record: record)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("执行记录")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadRecords(jobId: job.id) }
        .refreshable { await vm.loadRecords(jobId: job.id) }
        .navigationDestination(isPresented: Binding(
            get: { selectedRecord != nil },
            set: { if !$0 { selectedRecord = nil } }
        )) {
            if let record = selectedRecord, let taskID = record.taskID {
                CronjobLogView(taskID: taskID, record: record, vm: vm)
            }
        }
    }
}

struct CronjobRecordRow: View {
    let record: CronjobRecord

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(record.statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.startTime ?? "—")
                        .font(.subheadline.bold())
                    Spacer()
                    Text(record.statusDisplay)
                        .font(.caption.bold())
                        .foregroundStyle(record.statusColor)
                }
                HStack(spacing: 8) {
                    Text("耗时 \(record.durationDisplay)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let msg = record.message, !msg.isEmpty {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 日志查看

struct CronjobLogView: View {
    let taskID: String
    let record: CronjobRecord
    @ObservedObject var vm: CronjobsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if vm.isLoadingLog && vm.logLines.isEmpty {
                    ProgressView("加载中…")
                        .padding()
                } else if let err = vm.logError {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .padding()
                } else if vm.logLines.isEmpty {
                    Text("暂无日志")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(Array(vm.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 2)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
        .navigationTitle("执行日志")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadLog(taskID: taskID) }
    }
}

// MARK: - 创建计划任务

struct CreateCronjobView: View {
    @ObservedObject var vm: CronjobsViewModel
    let server: ServerConfig
    /// 编辑模式时传入已有的任务详情；创建模式传 nil。
    var editingJob: CronjobInfo? = nil
    @Environment(\.dismiss) private var dismiss

    /// 是否为编辑模式
    var isEditing: Bool { editingJob != nil }

    @State private var type: CronjobType = .shell
    @State private var name = ""
    // 周期
    @State private var specType: SpecType = .perDay
    @State private var hour = 2
    @State private var minute = 30
    @State private var week = 1        // 周日=0
    @State private var day = 1         // 每月几号
    // Shell
    @State private var script = "#!/bin/bash\n"
    @State private var user = ""           // 默认不选（空字符串 = 服务器默认）
    @State private var showScriptPicker = false
    // 备份
    @State private var retainCopies = 7
    @State private var backupAccountID = 0
    @State private var appSelection = "all"
    @State private var websiteSelection = "all"
    @State private var dbType: DBBackupType = .mysql
    @State private var dbSelection = "all"
    /// 选中的 mysqldump 备份参数（多选）。仅 MySQL / MariaDB 使用。
    @State private var dbBackupParams: Set<String> = []
    /// 控制备份参数多选 sheet 的弹出
    @State private var showBackupParamsPicker = false
    /// 标记是否已完成编辑模式的数据预填
    @State private var hasPrefilled = false

    enum DBBackupType: String, CaseIterable, Identifiable {
        case mysql = "mysql"
        case mariadb = "mariadb"
        case postgresql = "postgresql"
        case mongodb = "mongodb"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .mysql:      return "MySQL"
            case .mariadb:    return "MariaDB"
            case .postgresql: return "PostgreSQL"
            case .mongodb:    return "MongoDB"
            }
        }
        /// 是否支持备份参数（仅 MySQL / MariaDB）
        var supportsBackupParams: Bool {
            self == .mysql || self == .mariadb
        }
    }

    /// MySQL / MariaDB 备份参数选项（含参数值、简短说明、详细说明）
    static let backupParamOptions: [(value: String, summary: String, detail: String)] = [
        ("--single-transaction", "单一事务备份", "使用单一事务备份InnoDB表，适用于大数据量的备份"),
        ("--quick", "逐行读取", "逐行读取数据，而不是将整个表加载到内存中，适用于大数据量和低内存机器的备份"),
        ("--skip-lock-tables", "不锁定表", "不锁定所有表进行备份，适用于高并发的数据库"),
        ("--set-gtid-purged=OFF", "不导出GTID", "备份时不导出GTID信息，适用于组复制环境中的数据库恢复")
    ]

    /// 返回当前数据库类型可用的备份参数选项。
    /// 根据计划任务需求：MySQL 支持 4 项；MariaDB 仅支持前 3 项（不含 --set-gtid-purged=OFF）。
    var availableBackupParamOptions: [(value: String, summary: String, detail: String)] {
        switch dbType {
        case .mysql:      return Self.backupParamOptions
        case .mariadb:    return Self.backupParamOptions.filter { $0.value != "--set-gtid-purged=OFF" }
        default:          return []
        }
    }

    enum SpecType: String, CaseIterable, Identifiable {
        case perHour = "每小时"
        case perDay  = "每天"
        case perWeek = "每周"
        case perMonth = "每月"
        var id: String { rawValue }
        var raw: String {
            switch self {
            case .perHour: return "perHour"
            case .perDay:  return "perDay"
            case .perWeek: return "perWeek"
            case .perMonth: return "perMonth"
            }
        }
    }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("任务名称", text: $name)

                Picker("任务类型", selection: $type) {
                    ForEach(CronjobType.allCases) { t in
                        Label(t.displayName, systemImage: t.icon).tag(t)
                    }
                }
            }

            Section("执行周期") {
                Picker("周期", selection: $specType) {
                    ForEach(SpecType.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }

                Stepper("小时：\(hour) 时", value: $hour, in: 0...23)
                Stepper("分钟：\(minute) 分", value: $minute, in: 0...59)

                if specType == .perWeek {
                    Picker("星期", selection: $week) {
                        ForEach(0..<7) { w in
                            Text(weekDay(w)).tag(w)
                        }
                    }
                }
                if specType == .perMonth {
                    Stepper("日期：\(day) 号", value: $day, in: 1...28)
                }
            }

            switch type {
            case .shell:
                Section {
                    Button {
                        showScriptPicker = true
                    } label: {
                        Label("从脚本库选择", systemImage: "books.vertical")
                            .foregroundStyle(Color.accentColor)
                    }
                    TextEditor(text: $script)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 160)
                } header: { Text("脚本内容") }

                Section {
                    Picker("执行用户", selection: $user) {
                        Text("默认（不指定）").tag("")
                        ForEach(vm.systemUsers, id: \.self) { u in
                            Text(u).tag(u)
                        }
                    }
                } header: {
                    Text("执行设置")
                } footer: {
                    Text("不指定用户时，服务器将以默认用户执行脚本。")
                }

            case .app:
                Section("备份应用") {
                    Picker("范围", selection: $appSelection) {
                        Text("全部应用").tag("all")
                        ForEach(vm.installedApps, id: \.id) { app in
                            Text(app.name ?? "—").tag(app.key ?? "")
                        }
                    }
                }
                backupSection

            case .website:
                Section("备份网站") {
                    Picker("范围", selection: $websiteSelection) {
                        Text("全部网站").tag("all")
                        ForEach(vm.websiteOptions, id: \.id) { site in
                            Text(site.alias ?? site.primaryDomain ?? "—").tag(String(site.id))
                        }
                    }
                }
                backupSection

            case .database:
                Section("备份数据库") {
                    Picker("数据库类型", selection: $dbType) {
                        ForEach(DBBackupType.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .onChange(of: dbType) { _, newType in
                        dbSelection = "all"
                        dbBackupParams.removeAll()
                        Task { await vm.loadDBItems(dbType: newType.rawValue) }
                    }

                    Picker("范围", selection: $dbSelection) {
                        Text("全部数据库").tag("all")
                        ForEach(vm.dbItems, id: \.id) { item in
                            Text(item.name ?? "—").tag(String(item.id))
                        }
                    }
                }

                if dbType.supportsBackupParams {
                    Section {
                        Button {
                            showBackupParamsPicker = true
                        } label: {
                            HStack {
                                Text("备份参数")
                                Spacer()
                                Text(backupParamsSummary)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    } header: {
                        Text("备份参数")
                    } footer: {
                        Text("可选的 mysqldump 参数，支持多选，用于优化大数据量或特殊场景的备份。")
                    }
                }

                backupSection

            case .snapshot:
                backupSection
            }
        }
        .navigationTitle(isEditing ? "编辑计划任务" : "创建计划任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await submit() }
                } label: {
                    if vm.isCreating {
                        ProgressView()
                    } else {
                        Text(isEditing ? "保存" : "创建").bold()
                    }
                }
                .disabled(name.isEmpty || vm.isCreating)
            }
        }
        .task {
            await vm.loadCreateOptions()
            if let info = editingJob, !hasPrefilled {
                prefill(from: info)
                hasPrefilled = true
            }
            await vm.loadDBItems(dbType: dbType.rawValue)
        }
        .sheet(isPresented: $showScriptPicker) {
            NavigationStack {
                ScriptLibraryView(server: server) { picked in
                    if let code = picked.script, !code.isEmpty {
                        script = code
                    }
                    showScriptPicker = false
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { showScriptPicker = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showBackupParamsPicker) {
            BackupParamsPickerView(selection: $dbBackupParams, dbType: dbType)
        }
    }

    /// 备份参数摘要（用于创建表单的右侧预览文本）
    private var backupParamsSummary: String {
        if dbBackupParams.isEmpty {
            return "默认（无）"
        }
        return dbBackupParams.sorted().joined(separator: ", ")
    }

    @ViewBuilder
    private var backupSection: some View {
        Section("备份设置") {
            Stepper("保留份数：\(retainCopies) 份", value: $retainCopies, in: 1...100)

            Picker("备份账号", selection: $backupAccountID) {
                ForEach(vm.backupAccounts, id: \.id) { acc in
                    Text(acc.name ?? "—").tag(acc.id)
                }
            }
        }
    }

    private func weekDay(_ w: Int) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[w]
    }

    private func submit() async {
        var req = CronjobCreateRequest()
        req.name = name
        req.type = type.rawValue
        req.retainCopies = retainCopies
        // 默认分组（不传则任务会显示在「-」分组）
        req.groupID = vm.defaultGroupID

        // 周期
        var specObj = CronjobSpecObj()
        specObj.specType = specType.raw
        specObj.hour = hour
        specObj.minute = minute
        specObj.week = week
        specObj.day = day
        req.specObjs = [specObj]
        req.spec = buildCronSpec()
        req.specs = [req.spec]

        switch type {
        case .shell:
            req.script = script
            req.user = user
        case .app:
            req.appID = appSelection
            req.appIdList = [appSelection]
            req.sourceAccountIDs = backupAccountID > 0 ? String(backupAccountID) : ""
            req.downloadAccountID = backupAccountID
            req.sourceAccountItems = backupAccountID > 0 ? [backupAccountID] : []
        case .website:
            req.website = websiteSelection
            req.websiteList = [websiteSelection]
            req.sourceAccountIDs = backupAccountID > 0 ? String(backupAccountID) : ""
            req.downloadAccountID = backupAccountID
            req.sourceAccountItems = backupAccountID > 0 ? [backupAccountID] : []
        case .database:
            req.dbType = dbType.rawValue
            req.dbName = dbSelection
            req.dbNameList = [dbSelection]
            req.setBackupArgs(from: Array(dbBackupParams))
            req.sourceAccountIDs = backupAccountID > 0 ? String(backupAccountID) : ""
            req.downloadAccountID = backupAccountID
            req.sourceAccountItems = backupAccountID > 0 ? [backupAccountID] : []
        case .snapshot:
            req.sourceAccountIDs = backupAccountID > 0 ? String(backupAccountID) : ""
            req.downloadAccountID = backupAccountID
            req.sourceAccountItems = backupAccountID > 0 ? [backupAccountID] : []
        }

        if isEditing, let info = editingJob {
            req.id = info.id
            if await vm.update(req: req) {
                dismiss()
            }
        } else {
            if await vm.create(req: req) {
                dismiss()
            }
        }
    }

    /// 从已有任务详情预填表单字段
    private func prefill(from info: CronjobInfo) {
        name = info.name ?? ""
        type = info.jobType

        // 解析 cron 表达式回填周期控件
        if let spec = info.spec, !spec.isEmpty {
            parseSpec(spec)
        }

        // Shell
        if let s = info.script, !s.isEmpty {
            script = s
        }
        user = info.user ?? ""

        // 备份设置
        retainCopies = info.retainCopies ?? 7
        backupAccountID = info.downloadAccountID ?? 0

        // 各类型特定字段
        switch type {
        case .shell:
            break
        case .app:
            appSelection = info.appID ?? "all"
        case .website:
            websiteSelection = info.website ?? "all"
        case .database:
            if let dt = CreateCronjobView.DBBackupType(rawValue: info.dbType ?? "mysql") {
                dbType = dt
            }
            dbSelection = info.dbName ?? "all"
            dbBackupParams = info.backupParamSet
        case .snapshot:
            break
        }
    }

    /// 将 5 段 cron 表达式解析为 specType / hour / minute / week / day
    private func parseSpec(_ spec: String) {
        let parts = spec.split(separator: " ").map(String.init)
        guard parts.count >= 5 else { return }

        let minuteValue = Int(parts[0]) ?? 30
        let hourValue = Int(parts[1]) ?? 2

        minute = max(0, min(59, minuteValue))
        hour = max(0, min(23, hourValue))

        // parts[2] = day-of-month, parts[3] = month, parts[4] = day-of-week
        let dayOfMonth = parts[2]
        let dayOfWeek = parts[4]

        if dayOfMonth == "*" && dayOfWeek == "*" {
            // 检查是否每小时（hour 位置为 *）
            if parts[1] == "*" {
                specType = .perHour
            } else {
                specType = .perDay
            }
        } else if dayOfMonth != "*" {
            specType = .perMonth
            day = max(1, min(28, Int(dayOfMonth) ?? 1))
        } else if dayOfWeek != "*" {
            specType = .perWeek
            week = max(0, min(6, Int(dayOfWeek) ?? 0))
        } else {
            specType = .perDay
        }
    }

    /// 根据周期类型生成 cron 表达式
    private func buildCronSpec() -> String {
        let m = String(format: "%02d", minute)
        let h = String(format: "%02d", hour)
        switch specType {
        case .perHour:
            return "\(m) * * * *"
        case .perDay:
            return "\(m) \(h) * * *"
        case .perWeek:
            return "\(m) \(h) * * \(week)"
        case .perMonth:
            return "\(m) \(h) \(day) * *"
        }
    }
}

// MARK: - 备份参数多选视图

/// mysqldump 备份参数多选 Sheet。
/// 通过勾选切换 selection 中的成员；关闭即确认，无需额外保存按钮。
struct BackupParamsPickerView: View {
    @Binding var selection: Set<String>
    let dbType: CreateCronjobView.DBBackupType
    @Environment(\.dismiss) private var dismiss

    /// 当前数据库类型可用的参数选项
    private var options: [(value: String, summary: String, detail: String)] {
        switch dbType {
        case .mysql:
            return CreateCronjobView.backupParamOptions
        case .mariadb:
            return CreateCronjobView.backupParamOptions.filter {
                $0.value != "--set-gtid-purged=OFF"
            }
        default:
            return []
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(options, id: \.value) { opt in
                        Button {
                            toggle(opt.value)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selection.contains(opt.value) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(opt.value) ? Color.accentColor : .secondary)
                                    .font(.title3)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(opt.value)
                                        .font(.system(.callout, design: .monospaced))
                                        .foregroundStyle(.primary)
                                    Text(opt.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("\(dbType.displayName) 备份参数")
                } footer: {
                    Text("可多选；不选任何参数则使用默认方式备份。所选参数将以 args / argItems 形式提交给服务端。")
                }
            }
            .navigationTitle("备份参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .bold()
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("清除全部") {
                        selection.removeAll()
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle(_ value: String) {
        if selection.contains(value) {
            selection.remove(value)
        } else {
            selection.insert(value)
        }
    }
}

// MARK: - ViewModel

final class CronjobsViewModel: ObservableObject {
    @Published var cronjobs: [Cronjob] = []
    @Published var isLoading = false
    @Published var isCreating = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""

    /// 轻量提示（自动消失，无需确认）
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    /// 列表删除确认
    @Published var pendingDeleteJob: Cronjob?
    @Published var deleteCleanData = false

    /// 执行记录
    @Published var records: [CronjobRecord] = []
    @Published var isLoadingRecords = false

    /// 日志
    @Published var logLines: [String] = []
    @Published var isLoadingLog = false
    @Published var logError: String?

    /// 创建表单所需选项
    @Published var systemUsers: [String] = []
    @Published var backupAccounts: [BackupOption] = []
    @Published var installedApps: [InstalledAppOption] = []
    @Published var websiteOptions: [WebsiteOptionSimple] = []
    @Published var dbItems: [DBItemOption] = []
    @Published var isLoadingDBItems = false

    /// 默认分组 ID（创建任务时必须填，否则任务会显示在「-」分组）
    /// 从 POST /api/v2/core/groups/search (type=cronjob) 获取 isDefault=true 的项
    @Published var defaultGroupID: Int = 0

    private(set) var client: APIClient

    init(server: ServerConfig) {
        self.client = APIClient(server: server)
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let resp: CronjobListResponse = try await client.send(
                path: APIEndpoint.cronjobsSearch.path,
                body: CronjobSearchRequest(),
                as: CronjobListResponse.self
            )
            cronjobs = resp.items ?? []
        } catch let err as APIError {
            errorMessage = err.errorDescription
            showAlert(message: "加载失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            errorMessage = error.localizedDescription
            showAlert(message: "加载失败：\(error.localizedDescription)")
        }
    }

    func handle(job: Cronjob) async {
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.cronjobsHandle.path,
                body: CronjobHandleRequest(id: job.id),
                as: EmptyResponse.self
            )
            await refresh()
            showToast("任务「\(job.name ?? "")」已开始执行")
        } catch let err as APIError {
            showAlert(message: "执行失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "执行失败：\(error.localizedDescription)")
        }
    }

    @discardableResult
    func delete(job: Cronjob) async -> Bool {
        pendingDeleteJob = nil
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.cronjobsDelete.path,
                body: CronjobDeleteRequest(
                    ids: [job.id],
                    cleanData: deleteCleanData,
                    cleanRemoteData: deleteCleanData
                ),
                as: EmptyResponse.self
            )
            deleteCleanData = false
            showToast("任务「\(job.name ?? "")」已删除")
            await refresh()
            return true
        } catch let err as APIError {
            showAlert(message: "删除失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "删除失败：\(error.localizedDescription)")
            return false
        }
    }

    func create(req: CronjobCreateRequest) async -> Bool {
        isCreating = true
        defer { isCreating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.cronjobsCreate.path,
                body: req,
                as: EmptyResponse.self
            )
            await refresh()
            return true
        } catch let err as APIError {
            showAlert(message: "创建失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "创建失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 更新计划任务（POST /api/v2/cronjobs/update）
    @discardableResult
    func update(req: CronjobCreateRequest) async -> Bool {
        isCreating = true
        defer { isCreating = false }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.cronjobsUpdate.path,
                body: req,
                as: EmptyResponse.self
            )
            showToast("任务「\(req.name)」已更新")
            await refresh()
            return true
        } catch let err as APIError {
            showAlert(message: "更新失败：\(err.errorDescription ?? "未知错误")")
            return false
        } catch {
            showAlert(message: "更新失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 加载计划任务详情（POST /api/v2/cronjobs/load/info），用于编辑表单预填
    func loadCronjobInfo(id: Int) async -> CronjobInfo? {
        do {
            let info: CronjobInfo = try await client.send(
                path: APIEndpoint.cronjobsLoadInfo.path,
                body: CronjobLoadInfoRequest(id: id),
                as: CronjobInfo.self
            )
            return info
        } catch let err as APIError {
            showAlert(message: "加载详情失败：\(err.errorDescription ?? "未知错误")")
            return nil
        } catch {
            showAlert(message: "加载详情失败：\(error.localizedDescription)")
            return nil
        }
    }

    func loadRecords(jobId: Int) async {
        isLoadingRecords = true
        defer { isLoadingRecords = false }

        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let start = Calendar.current.date(byAdding: .month, value: -3, to: now) ?? now
        let startStr = df.string(from: start)
        let endStr = df.string(from: now)

        let req = CronjobRecordSearchRequest(
            page: 1, pageSize: 20,
            cronjobID: jobId,
            startTime: startStr, endTime: endStr,
            status: ""
        )
        do {
            let resp: CronjobRecordListResponse = try await client.send(
                path: APIEndpoint.cronjobsRecords.path,
                body: req,
                as: CronjobRecordListResponse.self
            )
            records = resp.items ?? []
        } catch let err as APIError {
            showAlert(message: "记录加载失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "记录加载失败：\(error.localizedDescription)")
        }
    }

    func loadLog(taskID: String) async {
        isLoadingLog = true
        logLines = []
        logError = nil
        defer { isLoadingLog = false }

        let req = CronjobLogRequest(page: 1, pageSize: 500, latest: true, taskID: taskID)
        do {
            let resp: CronjobLogResponse = try await client.send(
                path: APIEndpoint.logsTaskRead.path,
                body: req,
                as: CronjobLogResponse.self
            )
            logLines = resp.lines ?? []
        } catch {
            logError = error.localizedDescription
        }
    }

    func loadCreateOptions() async {
        // 默认分组（创建任务必须指定 groupID，否则任务会显示在「-」分组）
        if defaultGroupID == 0 {
            do {
                let groups: [CronjobGroup] = try await client.send(
                    path: APIEndpoint.cronjobsGroups.path,
                    body: CronjobGroupRequest(type: "cronjob"),
                    as: [CronjobGroup].self
                )
                // 优先取 isDefault=true 的项，否则取第一个
                if let def = groups.first(where: { $0.isDefault == true }) {
                    defaultGroupID = def.id
                } else if let first = groups.first {
                    defaultGroupID = first.id
                }
            } catch {
                // 加载失败保持 0，后端会用其默认值
            }
        }
        // 系统用户
        if systemUsers.isEmpty {
            do {
                systemUsers = try await client.send(
                    path: APIEndpoint.cronjobsUsers.path,
                    method: "GET",
                    as: [String].self
                )
            } catch {
                systemUsers = ["root"]
            }
        }
        // 备份账号
        if backupAccounts.isEmpty {
            do {
                backupAccounts = try await client.send(
                    path: APIEndpoint.cronjobsBackups.path,
                    method: "GET",
                    as: [BackupOption].self
                )
            } catch {
                backupAccounts = []
            }
        }
        // 已安装应用（用于备份应用）
        if installedApps.isEmpty {
            do {
                installedApps = try await client.send(
                    path: "/api/v2/apps/installed/list",
                    method: "GET",
                    as: [InstalledAppOption].self
                )
            } catch {
                installedApps = []
            }
        }
        // 网站列表（用于备份网站）
        if websiteOptions.isEmpty {
            do {
                websiteOptions = try await client.send(
                    path: "/api/v2/websites/options",
                    body: EmptyRequest(),
                    as: [WebsiteOptionSimple].self
                )
            } catch {
                websiteOptions = []
            }
        }
    }

    /// 加载指定类型的数据库实例列表（用于备份数据库任务）
    func loadDBItems(dbType: String) async {
        isLoadingDBItems = true
        dbItems = []
        do {
            dbItems = try await client.send(
                path: "/api/v2/databases/db/item/\(dbType)",
                method: "GET",
                as: [DBItemOption].self
            )
        } catch {
            dbItems = []
        }
        isLoadingDBItems = false
    }

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self?.toastMessage = nil }
        }
    }
}

// MARK: - 辅助轻量模型（创建表单下拉用）

/// 已安装应用简表（GET /api/v2/apps/installed/list）
struct InstalledAppOption: Decodable, Identifiable, Hashable {
    let id: Int
    let key: String?
    let name: String?
}

/// 网站简表（POST /api/v2/websites/options）
struct WebsiteOptionSimple: Decodable, Identifiable, Hashable {
    let id: Int
    let primaryDomain: String?
    let alias: String?
}

/// 空 POST body
struct EmptyRequest: Encodable {}
