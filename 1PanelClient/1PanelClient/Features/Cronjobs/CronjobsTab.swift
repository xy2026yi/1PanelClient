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

    /// 是否显示关闭按钮（fullScreen 模式用 true，作为分段内容时用 false）
    var showCloseButton: Bool = true

    init(manager: ServerManager, showCloseButton: Bool = true) {
        self.manager = manager
        self.showCloseButton = showCloseButton
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: CronjobsViewModel(server: server))
    }

    var body: some View {
        NavigationStack {
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
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button {
                            Task { await vm.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        if showCloseButton {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: Cronjob.self) { job in
                CronjobDetailView(job: job, vm: vm)
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateCronjobView(vm: vm)
            }
        }
        .task { await vm.refresh() }
        .alert(vm.alertMessage, isPresented: $vm.showAlert) {
            Button("好", role: .cancel) {}
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
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(job.jobType.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: job.jobType.icon)
                    .font(.title3)
                    .foregroundStyle(job.jobType.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(job.name ?? "未命名")
                    .font(.body.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(job.jobType.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(job.jobType.color.opacity(0.1))
                        .foregroundStyle(job.jobType.color)
                        .clipShape(Capsule())

                    Text(job.specDisplay)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
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
                Text("已停用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 任务详情

struct CronjobDetailView: View {
    let job: Cronjob
    @ObservedObject var vm: CronjobsViewModel

    var body: some View {
        List {
            Section("基本信息") {
                LabeledRow("名称", value: job.name ?? "—")
                LabeledRow("类型", value: job.jobType.displayName)
                LabeledRow("执行周期", value: job.specDisplay)
                LabeledRow("状态", value: job.isEnabled ? "启用" : "停用")
                LabeledRow("保留份数", value: job.retainCopiesDisplay)
                if let r = job.retryTimes, r > 0 {
                    LabeledRow("重试次数", value: "\(r) 次")
                }
                if let t = job.timeout, t > 0 {
                    LabeledRow("超时", value: "\(t)\(job.timeoutUnit ?? "s")")
                }
            }

            // 类型相关详情
            switch job.jobType {
            case .shell:
                if let user = job.user, !user.isEmpty {
                    Section("执行设置") {
                        LabeledRow("执行用户", value: user)
                        if job.inContainer == true {
                            LabeledRow("容器", value: job.containerName ?? "—")
                        }
                    }
                }
                if let script = job.script, !script.isEmpty {
                    Section {
                        Text(script)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } header: { Text("脚本内容") }
                }
            case .app:
                Section("备份内容") {
                    LabeledRow("备份对象", value: job.appID == "all" ? "全部应用" : (job.appID ?? "—"))
                }
            case .website:
                Section("备份内容") {
                    LabeledRow("备份对象", value: job.website == "all" ? "全部网站" : (job.website ?? "—"))
                }
            case .database:
                Section("备份内容") {
                    LabeledRow("备份对象", value: job.dbName == "all" ? "全部数据库" : (job.dbName ?? "—"))
                }
            case .snapshot:
                Section("备份内容") {
                    LabeledRow("类型", value: "系统快照")
                }
            }

            // 操作
            Section {
                Button {
                    Task { await vm.handle(job: job) }
                } label: {
                    Label("立即执行", systemImage: "play.fill")
                }
                NavigationLink {
                    CronjobRecordsView(job: job, vm: vm)
                } label: {
                    Label("执行记录", systemImage: "list.bullet.rectangle")
                }
            }

            // 危险操作
            Section {
                Button(role: .destructive) {
                    vm.pendingDeleteJob = job
                } label: {
                    Label("删除任务", systemImage: "trash")
                }
            } header: {
                Text("危险操作")
            } footer: {
                Text("删除后不可恢复，可选择是否同时删除已生成的备份文件")
            }
        }
        .navigationTitle(job.name ?? "任务详情")
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
                    Task { await vm.delete(job: j) }
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
        .sheet(item: $selectedRecord) { record in
            if let taskID = record.taskID {
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
    }
}

// MARK: - 日志查看

struct CronjobLogView: View {
    let taskID: String
    let record: CronjobRecord
    @ObservedObject var vm: CronjobsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if vm.isLoadingLog && vm.logLines.isEmpty {
                        ProgressView("加载中…")
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await vm.loadLog(taskID: taskID) }
        }
    }
}

// MARK: - 创建计划任务

struct CreateCronjobView: View {
    @ObservedObject var vm: CronjobsViewModel
    @Environment(\.dismiss) private var dismiss

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
    // 备份
    @State private var retainCopies = 7
    @State private var backupAccountID = 0
    @State private var appSelection = "all"
    @State private var websiteSelection = "all"
    @State private var dbSelection = "all"

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
        NavigationStack {
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
                        Picker("范围", selection: $dbSelection) {
                            Text("全部数据库").tag("all")
                        }
                    }
                    backupSection

                case .snapshot:
                    backupSection
                }
            }
            .navigationTitle("创建计划任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if vm.isCreating {
                            ProgressView()
                        } else {
                            Text("创建").bold()
                        }
                    }
                    .disabled(name.isEmpty || vm.isCreating)
                }
            }
            .task {
                await vm.loadCreateOptions()
            }
        }
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
            req.dbName = dbSelection
            req.dbNameList = [dbSelection]
            req.sourceAccountIDs = backupAccountID > 0 ? String(backupAccountID) : ""
            req.downloadAccountID = backupAccountID
            req.sourceAccountItems = backupAccountID > 0 ? [backupAccountID] : []
        case .snapshot:
            req.sourceAccountIDs = backupAccountID > 0 ? String(backupAccountID) : ""
            req.downloadAccountID = backupAccountID
            req.sourceAccountItems = backupAccountID > 0 ? [backupAccountID] : []
        }

        if await vm.create(req: req) {
            dismiss()
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

// MARK: - ViewModel

final class CronjobsViewModel: ObservableObject {
    @Published var cronjobs: [Cronjob] = []
    @Published var isLoading = false
    @Published var isCreating = false
    @Published var errorMessage: String?

    @Published var showAlert = false
    @Published var alertMessage = ""

    /// 列表删除确认
    @Published var pendingDeleteJob: Cronjob?
    @Published var deleteCleanData = false

    /// 执行记录
    @Published var records: [CronjobRecord] = []
    @Published var isLoadingRecords = false

    /// 日志
    @Published var logLines: [String] = []
    @Published var isLoadingLog = false

    /// 创建表单所需选项
    @Published var systemUsers: [String] = []
    @Published var backupAccounts: [BackupOption] = []
    @Published var installedApps: [InstalledAppOption] = []
    @Published var websiteOptions: [WebsiteOptionSimple] = []

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
            showAlert(message: "任务「\(job.name ?? "")」已开始执行")
            await refresh()
        } catch let err as APIError {
            showAlert(message: "执行失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "执行失败：\(error.localizedDescription)")
        }
    }

    func delete(job: Cronjob) async {
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
            showAlert(message: "任务已删除")
            await refresh()
        } catch let err as APIError {
            showAlert(message: "删除失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "删除失败：\(error.localizedDescription)")
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
            showAlert(message: "计划任务创建成功")
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
        defer { isLoadingLog = false }

        let req = CronjobLogRequest(page: 1, pageSize: 500, latest: true, taskID: taskID)
        do {
            let resp: CronjobLogResponse = try await client.send(
                path: APIEndpoint.websitesLogRead.path,
                body: req,
                as: CronjobLogResponse.self
            )
            logLines = resp.lines ?? []
        } catch let err as APIError {
            showAlert(message: "日志加载失败：\(err.errorDescription ?? "未知错误")")
        } catch {
            showAlert(message: "日志加载失败：\(error.localizedDescription)")
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

    private func showAlert(message: String) {
        alertMessage = message
        showAlert = true
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
