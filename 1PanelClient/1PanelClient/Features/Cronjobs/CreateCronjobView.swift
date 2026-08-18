//
//  CreateCronjobView.swift
//  1PanelClient
//

import SwiftUI

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
    // 周期（支持多个）
    @State private var schedules: [ScheduleItem] = [ScheduleItem()]
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
    /// 失败重试次数（所有任务类型通用）
    @State private var retryTimes = 3
    /// 超时时间的数值（单位由 timeoutUnit 决定）
    @State private var timeoutValue = 1
    /// 超时时间的单位（提交时统一换算成秒，timeoutUnit 固定为 "s"）
    @State private var timeoutUnit: TimeoutUnit = .hours

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

    /// 超时时间单位（仅 UI 表达，提交时统一换算成秒并以 timeoutUnit="s" 发送）
    enum TimeoutUnit: String, CaseIterable, Identifiable {
        case seconds = "秒"
        case minutes = "分钟"
        case hours   = "小时"
        var id: String { rawValue }

        /// 当前单位换算到秒的乘数
        var multiplier: Int {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours:   return 3600
            }
        }

        /// 从总秒数反推合适的单位与数值（编辑回填用）。
        /// 优先用最大可整除的单位；无法整除时回退到秒。
        static func from(seconds: Int) -> (unit: TimeoutUnit, value: Int) {
            if seconds >= 3600, seconds % 3600 == 0 {
                return (.hours, seconds / 3600)
            } else if seconds >= 60, seconds % 60 == 0 {
                return (.minutes, seconds / 60)
            } else {
                return (.seconds, max(seconds, 1))
            }
        }
    }

    /// 单个执行周期（支持多个周期组合）
    struct ScheduleItem: Identifiable {
        let id = UUID()
        var specType: SpecType = .perDay
        var hour: Int = 2
        var minute: Int = 30
        var week: Int = 1     // 周日=0
        var day: Int = 1      // 每月几号

        /// 生成对应的 cron 表达式
        var cronSpec: String {
            let m = String(format: "%02d", minute)
            let h = String(format: "%02d", hour)
            switch specType {
            case .perHour:  return "\(m) * * * *"
            case .perDay:   return "\(m) \(h) * * *"
            case .perWeek:  return "\(m) \(h) * * \(week)"
            case .perMonth: return "\(m) \(h) \(day) * *"
            }
        }

        /// 生成对应的 specObj（提交用）
        var specObj: CronjobSpecObj {
            var obj = CronjobSpecObj()
            obj.specType = specType.raw
            obj.hour = hour
            obj.minute = minute
            obj.week = week
            obj.day = day
            return obj
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

            Section {
                ForEach($schedules) { $item in
                    scheduleRow(for: $item)
                }

                Button {
                    schedules.append(ScheduleItem())
                } label: {
                    Label("添加周期", systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(schedules.count >= 10)
            } header: {
                Text("执行周期")
            } footer: {
                Text(schedules.count > 1 ? "已添加 \(schedules.count) 个周期，将按各周期分别执行。" : "支持添加多个周期，任务将在每个设定的时间点执行。")
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

            case .clean, .ntp, .syncIpGroup:
                // 这三种类型无备份账号、无类型特定配置，仅需保留份数
                Section("任务设置") {
                    Stepper("保留份数：\(retainCopies) 份", value: $retainCopies, in: 1...100)
                }
            }

            // 超时与重试（所有任务类型通用，放在各类型设置之后）
            Section("超时与重试") {
                Stepper("失败重试次数：\(retryTimes) 次", value: $retryTimes, in: 0...10)
                Picker("超时单位", selection: $timeoutUnit) {
                    ForEach(TimeoutUnit.allCases) { u in
                        Text(u.rawValue).tag(u)
                    }
                }
                .onChange(of: timeoutUnit) { oldUnit, newUnit in
                    // 切换单位时尽量保持总时长不变：按新单位取整
                    let totalSeconds = timeoutValue * oldUnit.multiplier
                    let newValue = max(1, totalSeconds / newUnit.multiplier)
                    timeoutValue = newValue
                }
                Stepper("超时时间：\(timeoutValue) \(timeoutUnit.rawValue)", value: $timeoutValue, in: 1...9999)
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

    /// 单个执行周期的编辑块（嵌入「执行周期」Section 内）。
    /// 使用 VStack + 内边距 + 圆角背景，让每个周期成为一个独立视觉区块，
    /// 避免直接堆在 List row 中导致 Stepper 点击区域重叠、控件过于紧凑。
    @ViewBuilder
    private func scheduleRow(for item: Binding<ScheduleItem>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部：周期标题 + 删除按钮
            HStack {
                Text("周期 \(index(of: item.wrappedValue) + 1)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                if schedules.count > 1 {
                    Button(role: .destructive) {
                        schedules.removeAll { $0.id == item.wrappedValue.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                            .accessibilityLabel("删除此周期")
                }
            }

            // 周期类型
            Picker("周期类型", selection: item.specType) {
                ForEach(SpecType.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }

            // 小时 / 分钟：每个 Stepper 单独成行并增加垂直留白，
            // 避免相邻 Stepper 的加减按钮视觉/点击区域重叠。
            Stepper("小时：\(item.wrappedValue.hour) 时", value: item.hour, in: 0...23)
                .padding(.vertical, 2)
            Stepper("分钟：\(item.wrappedValue.minute) 分", value: item.minute, in: 0...59)
                .padding(.vertical, 2)

            if item.wrappedValue.specType == .perWeek {
                Picker("星期", selection: item.week) {
                    ForEach(0..<7) { w in
                        Text(weekDay(w)).tag(w)
                    }
                }
            }
            if item.wrappedValue.specType == .perMonth {
                Stepper("日期：\(item.wrappedValue.day) 号", value: item.day, in: 1...28)
            }

            // 预览生成的 cron 表达式
            HStack {
                Text("表达式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.wrappedValue.cronSpec)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }

    /// 查找某个周期在数组中的下标（用于显示「周期 N」）
    private func index(of item: ScheduleItem) -> Int {
        schedules.firstIndex { $0.id == item.id } ?? 0
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

        // 周期（支持多个：spec 用 && 连接，specObjs 与 specs 逐项对应）
        let cronSpecs = schedules.map { $0.cronSpec }
        req.specObjs = schedules.map { $0.specObj }
        req.spec = cronSpecs.joined(separator: "&&")
        req.specs = cronSpecs

        // 超时与重试（所有任务类型通用；timeout 统一换算成秒，与抓包 timeoutUnit="s" 一致）
        let timeoutSeconds = timeoutValue * timeoutUnit.multiplier
        req.retryTimes = retryTimes
        req.timeout = timeoutSeconds
        req.timeoutItem = timeoutSeconds
        req.timeoutUnit = "s"

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
        case .clean, .ntp, .syncIpGroup:
            // 仅保留份数，无备份账号与类型特定字段
            break
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

        // 解析 cron 表达式回填周期控件（支持多个周期，spec 以 && 分隔）
        if let spec = info.spec, !spec.isEmpty {
            schedules = parseSchedules(spec)
        }

        // Shell
        if let s = info.script, !s.isEmpty {
            script = s
        }
        user = info.user ?? ""

        // 备份设置
        retainCopies = info.retainCopies ?? 7
        backupAccountID = info.downloadAccountID ?? 0

        // 超时与重试
        retryTimes = info.retryTimes ?? 3
        let (unit, value) = TimeoutUnit.from(seconds: info.timeout ?? 3600)
        timeoutUnit = unit
        timeoutValue = value

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
        case .clean, .ntp, .syncIpGroup:
            break
        }
    }

    /// 将 spec 字符串（可能包含多个以 && 连接的 cron 表达式）解析为周期数组。
    private func parseSchedules(_ spec: String) -> [ScheduleItem] {
        // 1Panel 多周期用 && 连接，例如 "30 1 * * 1&&30 2 * * 1"
        let cronSpecs = spec.components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
        var items: [ScheduleItem] = []
        for cron in cronSpecs where !cron.isEmpty {
            if let item = parseSingleSchedule(cron) {
                items.append(item)
            }
        }
        // 至少保留一个周期
        return items.isEmpty ? [ScheduleItem()] : items
    }

    /// 将单个 5 段 cron 表达式解析为一个 ScheduleItem。
    private func parseSingleSchedule(_ spec: String) -> ScheduleItem? {
        let parts = spec.split(separator: " ").map(String.init)
        guard parts.count >= 5 else { return nil }

        var item = ScheduleItem()
        item.minute = max(0, min(59, Int(parts[0]) ?? 30))
        item.hour = max(0, min(23, Int(parts[1]) ?? 2))

        // parts[2] = day-of-month, parts[3] = month, parts[4] = day-of-week
        let dayOfMonth = parts[2]
        let dayOfWeek = parts[4]

        if dayOfMonth == "*" && dayOfWeek == "*" {
            // 检查是否每小时（hour 位置为 *）
            if parts[1] == "*" {
                item.specType = .perHour
            } else {
                item.specType = .perDay
            }
        } else if dayOfMonth != "*" {
            item.specType = .perMonth
            item.day = max(1, min(28, Int(dayOfMonth) ?? 1))
        } else if dayOfWeek != "*" {
            item.specType = .perWeek
            item.week = max(0, min(6, Int(dayOfWeek) ?? 0))
        } else {
            item.specType = .perDay
        }
        return item
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

