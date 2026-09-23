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
    /// 所属分组（0 = 未初始化，加载后回落默认分组）
    @State private var selectedGroupID = 0
    // 周期（支持多个；编辑入口见 CronjobSchedulesEditorView）
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
    // 备份目录或文件（directory）
    /// 范围类型：dir=文件夹 file=文件
    @State private var dirScopeKey = "dir"
    /// 文件夹路径
    @State private var dirSourceText = ""
    /// 文件路径（一行一个，文件模式）
    @State private var filesText = ""
    /// 文件夹选择器（服务端目录浏览器）
    @State private var showDirPicker = false
    // 访问 URL（curl）：一行一个地址
    @State private var curlURLsText = ""
    // 压缩密码（备份产物压缩包，备份设置分组）
    @State private var compressSecret = ""
    // 告警分组（任务失败告警）
    @State private var hasAlert = false
    @State private var alertMethodIDs: Set<Int> = []
    @State private var alertCount = 3
    @State private var showAlertMethodPicker = false
    /// 标记是否已完成编辑模式的数据预填
    @State private var hasPrefilled = false
    /// 预填进行中（屏蔽 dbType 等程序化赋值触发的 onChange 联动重置）
    @State private var isPrefilling = false
    /// 失败重试次数（所有任务类型通用）
    @State private var retryTimes = 3
    /// 超时时间的数值（单位由 timeoutUnit 决定）
    @State private var timeoutValue = 1
    /// 超时时间的单位（提交时统一换算成秒，timeoutUnit 固定为 "s"）
    @State private var timeoutUnit: TimeoutUnit = .hours
    /// 备份目录输入框聚焦态（描边框联动）
    @FocusState private var dirFieldFocused: Bool

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
        ("--single-transaction", L10n.t("单一事务备份"), L10n.t("使用单一事务备份InnoDB表，适用于大数据量的备份")),
        ("--quick", L10n.t("逐行读取"), L10n.t("逐行读取数据，而不是将整个表加载到内存中，适用于大数据量和低内存机器的备份")),
        ("--skip-lock-tables", L10n.t("不锁定表"), L10n.t("不锁定所有表进行备份，适用于高并发的数据库")),
        ("--set-gtid-purged=OFF", L10n.t("不导出GTID"), L10n.t("备份时不导出GTID信息，适用于组复制环境中的数据库恢复"))
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

    /// 向导分页：0 基础（信息/周期） 1 内容（类型特定） 2 高级（超时重试）
    @State private var wizardPage = 0
    private let wizardPageNames = [L10n.t("基础"), L10n.t("内容"), L10n.t("高级")]

    var body: some View {
        VStack(spacing: 0) {
            WizardStepsBar(pageNames: wizardPageNames, current: wizardPage)
            Form {
                Group {
                    switch wizardPage {
                    case 0:
                        basicInfoSection
                        scheduleSection
                    case 1:
                        contentSections
                        alertSection
                    default:
                        timeoutSection
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WizardBottomBar(
                page: wizardPage,
                totalPages: wizardPageNames.count,
                primaryTitle: isEditing ? L10n.t("保存") : L10n.t("创建"),
                isBusy: vm.isCreating,
                primaryDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty
                    || (wizardPage >= 1 && !contentValid),
                onBack: { withAnimation { wizardPage -= 1 } },
                onNext: { withAnimation { wizardPage += 1 } },
                onPrimary: { Task { await submit() } }
            )
        }
        .animation(.easeInOut(duration: 0.22), value: wizardPage)
        .navigationTitle(isEditing ? L10n.t("编辑计划任务") : L10n.t("创建计划任务"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .task {
        await vm.loadCreateOptions()
        if selectedGroupID == 0 { selectedGroupID = vm.defaultGroupID }
        // 备份账号默认选中第一个（与网页端一致，localhost 恒在首位）：
        // 选择器的显示回落不落状态，用户未手动切换时提交会带空账号，
        // 服务端执行备份时报「获取备份账号连接失败」。编辑态随后由 prefill 覆盖。
        if backupAccountID == 0, let first = vm.backupAccounts.first {
            backupAccountID = first.id
        }
        if let info = editingJob, !hasPrefilled {
            // 预填期间屏蔽 onChange 联动：dbType 程序化赋值会触发
            // 「重置范围/清空备份参数」分支，覆盖刚回填的库名与参数
            isPrefilling = true
            prefill(from: info)
            hasPrefilled = true
            // onChange 在视图更新时才触发（晚于同步预填），下一轮 runloop 解除守卫
            DispatchQueue.main.async { isPrefilling = false }
        }
        await vm.loadDBItems(dbType: dbType.rawValue)
        }
        .onChange(of: vm.groups) { _, _ in
        // 分组数据晚于表单出现时回落默认分组（选中项被删时找回）
        if selectedGroupID == 0 || !vm.groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = vm.defaultGroupID
        }
        }
        // 备份参数多选（MySQL 家族；点击入口行弹出，选中集直接回写）
        .sheet(isPresented: $showBackupParamsPicker) {
            NavigationStack {
                BackupArgsPicker(dbType: dbType.rawValue, selection: $dbBackupParams)
                    .navigationTitle(L10n.t("备份参数"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.t("完成")) { showBackupParamsPicker = false }
                        }
                    }
            }
        }
        // 备份目录或文件：文件夹范围选择器（服务端目录浏览器）
        .sheet(isPresented: $showDirPicker) {
            DirectoryPickerSheet(client: vm.client) { path in
                dirSourceText = path
            }
        }
        // 告警方式多选（勾选即回写，关闭即确认）
        .sheet(isPresented: $showAlertMethodPicker) {
            CronjobAlertMethodsPickerView(methods: vm.alertMethods,
                                          selection: $alertMethodIDs)
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
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { showScriptPicker = false }
                }
            }
        }
    }    }

    // MARK: - 向导分页成员（自单页表单拆出）

    private var basicInfoSection: some View {
        Section(L10n.t("基本信息")) {
            OutlinedTextField(label: L10n.t("任务名称"), text: $name)

            OutlinedPicker(label: L10n.t("任务类型"), options: CronjobType.allCases,
                           selection: $type) { $0.displayName }

            // 分组（未加载到分组数据时仅展示默认分组占位）
            if vm.groups.isEmpty {
                HStack {
                    Text(L10n.t("分组"))
                    Spacer()
                    Text(L10n.t("默认分组"))
                        .foregroundStyle(.secondary)
                }
            } else {
                OutlinedPicker(label: L10n.t("分组"),
                               options: groupOptionKeys, selection: groupText,
                               optionLabels: groupOptionLabels)
            }
        }
    }

    /// 分组选项（"0"=默认分组兜底，避免选择初值无对应项的运行时警告）
    private var groupOptionKeys: [String] {
        ["0"] + vm.groups.map { String($0.id) }
    }

    private var groupOptionLabels: [String: String] {
        var labels = ["0": L10n.t("默认分组")]
        for group in vm.groups { labels[String(group.id)] = group.displayName }
        return labels
    }

    private var groupText: Binding<String> {
        Binding<String>(
            get: {
                vm.groups.contains(where: { $0.id == selectedGroupID })
                    ? String(selectedGroupID) : "0"
            },
            set: { selectedGroupID = Int($0) ?? 0 }
        )
    }

    /// 执行周期：入口行（N 个周期）→ 子编辑页（形态 8，与创建容器端口/挂载同模式）
    private var scheduleSection: some View {
        Section {
            NavigationLink {
                CronjobSchedulesEditorView(server: server, schedules: $schedules)
            } label: {
                HStack {
                    Text(L10n.t("执行周期"))
                    Spacer()
                    Text(L10n.f("%ld 个周期", schedules.count))
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(schedules.count > 1 ? L10n.f("已添加 %ld 个周期，将按各周期分别执行。", schedules.count) : L10n.t("支持添加多个周期，任务将在每个设定的时间点执行。"))
        }
    }

    @ViewBuilder
    private var contentSections: some View {
        switch type {
        case .shell:
            Section {
                Button {
                    showScriptPicker = true
                } label: {
                    Label(L10n.t("从脚本库选择"), systemImage: "books.vertical")
                        .foregroundStyle(Color.accentColor)
                }
                OutlinedMultiLineField(label: L10n.t("脚本内容"),
                                       prompt: "#!/bin/bash",
                                       lines: 8, fixedLines: 8,
                                       zoomable: true, monospaced: true,
                                       text: $script)
            } header: { Text(L10n.t("脚本内容")) }

            Section {
                OutlinedPicker(label: L10n.t("执行用户"),
                               options: userOptionKeys, selection: $user,
                               optionLabels: userOptionLabels)
            } header: {
                Text(L10n.t("执行设置"))
            } footer: {
                Text(L10n.t("不指定用户时，服务器将以默认用户执行脚本。"))
            }

        case .app:
            Section(L10n.t("备份应用")) {
                OutlinedPicker(label: L10n.t("范围"),
                               options: appScopeOptions, selection: $appSelection,
                               optionLabels: appScopeLabels)
            }
            backupSection

        case .website:
            Section(L10n.t("备份网站")) {
                OutlinedPicker(label: L10n.t("范围"),
                               options: websiteScopeOptions, selection: $websiteSelection,
                               optionLabels: websiteScopeLabels)
            }
            backupSection

        case .database:
            Section(L10n.t("备份数据库")) {
                OutlinedPicker(label: L10n.t("数据库类型"), options: DBBackupType.allCases,
                               selection: $dbType) { $0.displayName }
                    .onChange(of: dbType) { _, newType in
                        // 预填期间的程序化赋值不触发重置（编辑 mysql 以外类型时
                        // 回填的库名/备份参数会被清成 all/空，保存即覆盖原值）
                        guard !isPrefilling else { return }
                        dbSelection = "all"
                        dbBackupParams.removeAll()
                        Task { await vm.loadDBItems(dbType: newType.rawValue) }
                    }

                OutlinedPicker(label: L10n.t("范围"),
                               options: dbScopeOptions, selection: $dbSelection,
                               optionLabels: dbScopeLabels)
            }

            if dbType.supportsBackupParams {
                Section {
                    Button {
                        showBackupParamsPicker = true
                    } label: {
                        HStack {
                            Text(L10n.t("备份参数"))
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
                    Text(L10n.t("备份参数"))
                } footer: {
                    Text(L10n.t("可选的 mysqldump 参数，支持多选，用于优化大数据量或特殊场景的备份。"))
                }
            }

            backupSection

        case .snapshot:
            backupSection

        case .directory:
            directorySection
            backupSection

        case .log:
            // 备份日志：无类型特定字段，仅备份设置分组
            backupSection

        case .curl:
            Section {
                OutlinedMultiLineField(label: L10n.t("URL 地址"), lines: 4, fixedLines: 4,
                                       zoomable: true,
                                       text: $curlURLsText)
            } header: {
                Text(L10n.t("访问 URL"))
            } footer: {
                Text(L10n.t("一行一个地址，任务执行时将依次访问"))
            }
            retainOnlySection

        case .cutWebsiteLog:
            Section(L10n.t("切割网站日志")) {
                OutlinedPicker(label: L10n.t("网站"),
                               options: websiteScopeOptions, selection: $websiteSelection,
                               optionLabels: websiteScopeLabels)
            }
            retainOnlySection

        case .cleanLog:
            Section(L10n.t("清理日志")) {
                OutlinedPicker(label: L10n.t("清理类型"),
                               options: ["website"],
                               selection: .constant("website"),
                               optionLabels: ["website": L10n.t("网站日志")])
            }
            retainOnlySection

        case .clean, .ntp, .syncIpGroup:
            // 这三种类型无备份账号、无类型特定配置，仅需保留份数
            Section(L10n.t("任务设置")) {
                OutlinedUnitField(label: L10n.t("保留份数"), unit: L10n.t("份"),
                                  text: retainCopiesText, range: 1...100)
            }
        }
    }

    /// 备份目录或文件：范围类型 + 文件夹输入框（含文件浏览器图标）/ 文件编辑页入口
    private var directorySection: some View {
        Section(L10n.t("备份目录或文件")) {
            OutlinedPicker(label: L10n.t("类型"),
                           options: ["dir", "file"], selection: $dirScopeKey,
                           optionLabels: [
                            "dir": L10n.t("文件夹"),
                            "file": L10n.t("文件")
                           ])

            if dirScopeKey == "dir" {
                // 文件夹：输入框 + 框内右侧文件浏览器图标，选中目录后自动回填
                OutlinedShape(label: L10n.t("范围"),
                              isFocused: dirFieldFocused,
                              hasValue: !dirSourceText.isEmpty,
                              trailing: {
                    Button {
                        showDirPicker = true
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.t("选择目录"))
                }) {
                    TextField("", text: $dirSourceText)
                        .keyboardType(.URL)
                        .focused($dirFieldFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } else {
                // 文件：点击跳转编辑页（形态 7.1，一行一个，可从文件浏览器追加）
                NavigationLink {
                    CronjobFilesEditorView(server: server, text: $filesText)
                } label: {
                    HStack {
                        Text(L10n.t("范围"))
                        Spacer()
                        Text(fileScopeSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// 文件模式范围摘要（N 个文件 / 未设置）
    private var fileScopeSummary: String {
        let count = nonEmptyLines(filesText).count
        return count == 0 ? L10n.t("未设置") : L10n.f("%ld 个文件", count)
    }

    /// 多行文本取非空行
    private func nonEmptyLines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 内容页必填校验（目录范围 / URL 地址；开启告警须至少选一种方式）
    private var contentValid: Bool {
        switch type {
        case .directory:
            guard dirScopeKey == "dir"
                ? !nonEmptyLines(dirSourceText).isEmpty
                : !nonEmptyLines(filesText).isEmpty else { return false }
        case .curl:
            guard !nonEmptyLines(curlURLsText).isEmpty else { return false }
        default:
            break
        }
        if hasAlert, alertMethodIDs.isEmpty { return false }
        return true
    }

    /// 任务设置分组（无备份账号，仅保留份数）：访问 URL / 切割网站日志 / 清理日志
    private var retainOnlySection: some View {
        Section(L10n.t("任务设置")) {
            OutlinedUnitField(label: L10n.t("保留份数"), unit: L10n.t("份"),
                              text: retainCopiesText, range: 1...100)
        }
    }

    /// 超时与重试（所有任务类型通用，放在各类型设置之后）
    private var timeoutSection: some View {
        Section(L10n.t("超时与重试")) {
            OutlinedTextField(label: L10n.t("失败重试次数"),
                              text: retryTimesText, keyboardType: .numberPad)
            OutlinedTextField(label: L10n.t("超时时间"),
                              text: timeoutText, keyboardType: .numberPad)
            OutlinedPicker(label: L10n.t("超时单位"),
                           options: TimeoutUnit.allCases,
                           selection: $timeoutUnit) { L10n.t($0.rawValue) }
                .onChange(of: timeoutUnit) { oldUnit, newUnit in
                    // 切换单位时尽量保持总时长不变：按新单位取整
                    let totalSeconds = timeoutValue * oldUnit.multiplier
                    let newValue = max(1, totalSeconds / newUnit.multiplier)
                    timeoutValue = newValue
                }
        }
    }

    /// 失败重试次数 Int ↔ String（输入钳制 0...10，对齐原 Stepper 范围）
    private var retryTimesText: Binding<String> {
        Binding<String>(get: { String(retryTimes) },
                        set: { text in clampInt(text, into: 0...10) { retryTimes = $0 } })
    }

    /// 超时时间 Int ↔ String（输入钳制 1...9999，对齐原 Stepper 范围）
    private var timeoutText: Binding<String> {
        Binding<String>(get: { String(timeoutValue) },
                        set: { text in clampInt(text, into: 1...9999) { timeoutValue = $0 } })
    }

    /// 保留份数 Int ↔ String（输入钳制 1...100，对齐原 Stepper 范围）
    private var retainCopiesText: Binding<String> {
        Binding<String>(get: { String(retainCopies) },
                        set: { text in clampInt(text, into: 1...100) { retainCopies = $0 } })
    }

    /// 数字文本钳制：非法输入保持原值，超出范围收敛到边界
    private func clampInt(_ text: String, into range: ClosedRange<Int>, set: (Int) -> Void) {
        guard let parsed = Int(text) else { return }
        set(min(max(parsed, range.lowerBound), range.upperBound))
    }


    /// 备份应用范围选项（"all"=全部应用）
    private var appScopeOptions: [String] {
        ["all"] + vm.installedApps.compactMap { $0.key }
    }
    private var appScopeLabels: [String: String] {
        var labels = ["all": L10n.t("全部应用")]
        for app in vm.installedApps {
            if let key = app.key { labels[key] = app.name ?? "—" }
        }
        return labels
    }

    /// 备份网站范围选项（"all"=全部网站）
    private var websiteScopeOptions: [String] {
        ["all"] + vm.websiteOptions.map { String($0.id) }
    }
    private var websiteScopeLabels: [String: String] {
        var labels = ["all": L10n.t("全部网站")]
        for site in vm.websiteOptions {
            labels[String(site.id)] = site.alias ?? site.primaryDomain ?? "—"
        }
        return labels
    }

    /// 数据库范围选项（"all"=全部数据库）
    private var dbScopeOptions: [String] {
        ["all"] + vm.dbItems.map { String($0.id) }
    }
    private var dbScopeLabels: [String: String] {
        var labels = ["all": L10n.t("全部数据库")]
        for item in vm.dbItems {
            labels[String(item.id)] = item.name ?? "—"
        }
        return labels
    }

    /// 备份账号选项与 Int ↔ String 绑定（描边菜单用）
    private var backupAccountOptions: [String] {
        vm.backupAccounts.map { String($0.id) }
    }
    private var backupAccountLabels: [String: String] {
        var labels: [String: String] = [:]
        for acc in vm.backupAccounts {
            labels[String(acc.id)] = acc.name ?? "—"
        }
        return labels
    }
    private var backupAccountText: Binding<String> {
        Binding<String>(
            get: { vm.backupAccounts.contains(where: { $0.id == backupAccountID })
                ? String(backupAccountID) : String(vm.backupAccounts.first?.id ?? 0) },
            set: { backupAccountID = Int($0) ?? 0 })
    }

    /// 执行用户选项（""=默认（不指定））
    private var userOptionKeys: [String] {
        [""] + vm.systemUsers
    }

    private var userOptionLabels: [String: String] {
        ["": L10n.t("默认（不指定）")]
    }

    /// 备份参数摘要（用于创建表单的右侧预览文本）
    private var backupParamsSummary: String {
        if dbBackupParams.isEmpty {
            return L10n.t("默认（无）")
        }
        return dbBackupParams.sorted().joined(separator: ", ")
    }

    @ViewBuilder
    private var backupSection: some View {
        Section(L10n.t("备份设置")) {
            OutlinedUnitField(label: L10n.t("保留份数"), unit: L10n.t("份"),
                              text: retainCopiesText, range: 1...100)

            OutlinedPicker(label: L10n.t("备份账号"),
                           options: backupAccountOptions, selection: backupAccountText,
                           optionLabels: backupAccountLabels)

            if type.supportsCompressionSecret {
                OutlinedPasswordField(label: L10n.t("压缩密码"), text: $compressSecret)
            }
        }
    }

    // MARK: - 告警分组（第 2 页通用）

    /// 任务失败告警：开关 + 告警方式多选 + 告警次数
    private var alertSection: some View {
        Section {
            Toggle(L10n.t("告警"), isOn: $hasAlert)

            if hasAlert {
                Button {
                    showAlertMethodPicker = true
                } label: {
                    HStack {
                        Text(L10n.t("告警方式"))
                        Spacer()
                        Text(alertMethodSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                OutlinedTextField(label: L10n.t("告警次数"),
                                  text: alertCountText, keyboardType: .numberPad)
            }
        } header: {
            Text(L10n.t("告警"))
        } footer: {
            Text(L10n.t("任务失败达到告警次数后，将通过所选方式发送通知"))
        }
    }

    /// 告警方式选中摘要（已选方式名 / 未选择 / 未配置发送方式）
    private var alertMethodSummary: String {
        guard !vm.alertMethods.isEmpty else {
            return L10n.t("未配置发送方式")
        }
        let selected = vm.alertMethods
            .filter { alertMethodIDs.contains($0.id) }
            .compactMap { $0.sendConfig.displayName }
        if selected.isEmpty { return L10n.t("未选择") }
        return selected.joined(separator: "、")
    }

    /// 告警次数 Int ↔ String（输入钳制 1...99，默认 3）
    private var alertCountText: Binding<String> {
        Binding<String>(get: { String(alertCount) },
                        set: { text in clampInt(text, into: 1...99) { alertCount = $0 } })
    }

    /// 单个执行周期的编辑已迁移至 CronjobSchedulesEditorView（入口行进入）

    private func submit() async {
        var req = CronjobCreateRequest()
        req.name = name
        req.type = type.rawValue
        req.retainCopies = retainCopies
        // 分组（0 = 未选中，回落默认分组）
        req.groupID = selectedGroupID != 0 ? selectedGroupID : vm.defaultGroupID

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
            req.secret = compressSecret
        case .website:
            req.website = websiteSelection
            req.websiteList = [websiteSelection]
            req.sourceAccountIDs = backupAccountID > 0 ? String(backupAccountID) : ""
            req.downloadAccountID = backupAccountID
            req.sourceAccountItems = backupAccountID > 0 ? [backupAccountID] : []
            req.secret = compressSecret
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
            req.secret = compressSecret
        case .directory:
            req.sourceAccountIDs = backupAccountID > 0 ? String(backupAccountID) : ""
            req.downloadAccountID = backupAccountID
            req.sourceAccountItems = backupAccountID > 0 ? [backupAccountID] : []
            req.secret = compressSecret
            if dirScopeKey == "dir" {
                req.isDir = true
                req.files = []
                req.sourceDir = dirSourceText.trimmingCharacters(in: .whitespaces)
            } else {
                let files = nonEmptyLines(filesText)
                req.isDir = false
                req.files = files.map { CronjobFileItem(val: $0) }
                req.sourceDir = files.joined(separator: ",")
            }
        case .log:
            req.sourceAccountIDs = backupAccountID > 0 ? String(backupAccountID) : ""
            req.downloadAccountID = backupAccountID
            req.sourceAccountItems = backupAccountID > 0 ? [backupAccountID] : []
            req.secret = compressSecret
        case .curl:
            let urls = nonEmptyLines(curlURLsText)
            req.url = urls.joined(separator: ",")
            req.urlItems = urls.isEmpty ? [""] : urls
        case .cutWebsiteLog:
            req.website = websiteSelection
            req.websiteList = [websiteSelection]
        case .cleanLog:
            req.scopes = ["website"]
        case .clean, .ntp, .syncIpGroup:
            // 仅保留份数，无备份账号与类型特定字段
            break
        }

        // 告警分组（所有类型通用；标题格式对齐 Web 端「计划任务-类型「 任务名 」任务失败告警」）
        if hasAlert {
            req.hasAlert = true
            req.alertCount = alertCount
            req.alertTitle = L10n.f("计划任务-%@「 %@ 」任务失败告警", type.displayName, name)
            // 只提交现存发送方式的 id（编辑回填可能含已删除的方式）
            let validIDs = Set(vm.alertMethods.map(\.id))
            let ids = alertMethodIDs
                .filter { validIDs.contains($0) || vm.alertMethods.isEmpty }
                .map(String.init)
                .sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
            req.alertMethod = ids.joined(separator: ",")
            req.alertMethodItems = ids
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
        // 分组（沿用任务原分组）
        selectedGroupID = info.groupID ?? 0

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
        compressSecret = info.secret ?? ""

        // 超时与重试
        retryTimes = info.retryTimes ?? 3
        let (unit, value) = TimeoutUnit.from(seconds: info.timeout ?? 3600)
        timeoutUnit = unit
        timeoutValue = value

        // 告警分组
        hasAlert = info.hasAlert ?? false
        if let count = info.alertCount, count > 0 {
            alertCount = count
        }
        alertMethodIDs = info.alertMethodIDSet

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
        case .directory:
            let isDir = info.isDir ?? true
            dirScopeKey = isDir ? "dir" : "file"
            if isDir {
                dirSourceText = info.sourceDir ?? ""
            } else {
                // files 数组优先，缺失时回退 sourceDir 逗号分隔
                let list = info.filePathList
                if list.isEmpty, let raw = info.sourceDir, !raw.isEmpty {
                    filesText = raw.split(separator: ",").map(String.init).joined(separator: "\n")
                } else {
                    filesText = list.joined(separator: "\n")
                }
            }
        case .log:
            break
        case .curl:
            // urlItems 数组优先，缺失时回退 url 逗号分隔
            let items = (info.urlItems ?? []).filter { !$0.isEmpty }
            if items.isEmpty, let raw = info.url, !raw.isEmpty {
                curlURLsText = raw.split(separator: ",").map(String.init).joined(separator: "\n")
            } else {
                curlURLsText = items.joined(separator: "\n")
            }
        case .cutWebsiteLog:
            websiteSelection = info.website ?? "all"
        case .cleanLog:
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

