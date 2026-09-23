//
//  CronjobFormSubViews.swift
//  1PanelClient
//
//  执行周期编辑页 + 文件范围编辑页 + 告警方式多选（自 CreateCronjobView.swift 拆出，内容未改动）
//

import SwiftUI

// MARK: - 通用多选 Sheet（备份账号 / 备份应用 / 备份网站 / 数据库范围共用）

/// 多选项（id 即提交值；title 主显示；subtitle 次行说明，如账号类型）
struct CronjobMultiOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
}

/// 有序多选列表：选择顺序保留（服务端 appID/website/dbName 按逗号拼接，顺序即选择顺序）
struct CronjobMultiPickerSheet: View {
    let title: String
    let options: [CronjobMultiOption]
    /// 空 = 未选择（调用方保证至少选一项后再提交）
    @Binding var selection: [String]
    var footer: String? = nil
    /// 「全部」项的 id（如 "all"）：非 nil 时启用互斥——选「全部」清空单项、
    /// 选单项移除「全部」；非「全部」项全选时自动折算为「全部」
    var exclusiveAllKey: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if options.isEmpty {
                    Section {
                        ContentUnavailableView(
                            L10n.t("暂无可选项"),
                            systemImage: "list.bullet",
                            description: Text(L10n.t("请稍后重试或检查服务端数据"))
                        )
                        .padding(.vertical, 20)
                    }
                } else {
                    Section {
                        ForEach(options) { option in
                            Button {
                                toggle(option.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selection.contains(option.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection.contains(option.id)
                                                         ? Color.accentColor : .secondary)
                                        .font(.title3)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(option.title)
                                            .foregroundStyle(.primary)
                                        if let sub = option.subtitle, !sub.isEmpty {
                                            Text(sub)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        if let footer {
                            Text(footer)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成")) { dismiss() }
                        .bold()
                }
            }
        }
        .bottomSheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func toggle(_ id: String) {
        if let idx = selection.firstIndex(of: id) {
            selection.remove(at: idx)
            return
        }
        if let all = exclusiveAllKey {
            if id == all {
                // 选「全部」：清空单项，仅保留 all
                selection = [all]
                return
            }
            // 选单项：移除 all；全部单项选中时折算为 all
            var picked = selection.filter { $0 != all }
            picked.append(id)
            let nonAllOptions = options.map(\.id).filter { $0 != all }
            selection = Set(picked) == Set(nonAllOptions) ? [all] : picked
            return
        }
        selection.append(id)
    }
}

// MARK: - 执行周期编辑页（入口行进入，形态 8：每周期一个 Section + 底部添加）

/// 周期列表编辑：每周期一个 Section（类型/小时/分钟，每月加日期、每周加星期），
/// 头部「删除周期」（存在多个周期才出现）；页尾预览执行时间 + 添加
struct CronjobSchedulesEditorView: View {
    let server: ServerConfig
    @Binding var schedules: [CreateCronjobView.ScheduleItem]

    /// 周期预览（cronjobs/next 返回的每个周期接下来 5 次执行时间）
    @State private var isPreviewing = false
    @State private var previewResults: [(spec: String, times: [String])] = []
    /// 预览请求失败的周期数（>0 时在预览区尾部提示，避免全部失败时无反馈）
    @State private var previewFailedCount = 0

    var body: some View {
        Form {
            ForEach($schedules) { $item in
                scheduleSection($item)
            }

            Section {
                Button {
                    Task { await previewSchedules() }
                } label: {
                    Label(L10n.t("预览执行时间"), systemImage: "clock.badge.questionmark")
                        .foregroundStyle(Color.accentColor)
                }
                if isPreviewing {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(Array(previewResults.enumerated()), id: \.offset) { _, result in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.spec)
                            .font(.dataMonospacedCaption)
                            .foregroundStyle(.secondary)
                        ForEach(result.times, id: \.self) { time in
                            Text(time)
                                .font(.dataMonospacedCaption)
                        }
                    }
                }
                if previewFailedCount > 0 {
                    Label(L10n.f("%ld 个周期预览失败", previewFailedCount),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    schedules.append(CreateCronjobView.ScheduleItem())
                } label: {
                    Label(L10n.t("添加"), systemImage: "plus.circle")
                        .foregroundStyle(Color.accentColor)
                }
                .disabled(schedules.count >= 10)
            }
        }
        .navigationTitle(L10n.t("执行周期"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 单个周期：头部「周期-N + 删除周期」，字段描边化（类型/星期 形态 3，小时/分钟/日期 形态 1）
    private func scheduleSection(_ item: Binding<CreateCronjobView.ScheduleItem>) -> some View {
        Section {
            OutlinedPicker(label: L10n.t("类型"),
                           options: CreateCronjobView.SpecType.allCases,
                           selection: item.specType) { L10n.t($0.rawValue) }
            OutlinedTextField(label: L10n.t("小时"), text: intText(item.hour, range: 0...23),
                              keyboardType: .numberPad)
            OutlinedTextField(label: L10n.t("分钟"), text: intText(item.minute, range: 0...59),
                              keyboardType: .numberPad)
            if item.wrappedValue.specType == .perMonth {
                OutlinedTextField(label: L10n.t("日期"), text: intText(item.day, range: 1...28),
                                  keyboardType: .numberPad)
            }
            if item.wrappedValue.specType == .perWeek {
                OutlinedPicker(label: L10n.t("星期"),
                               options: (0..<7).map(String.init),
                               selection: weekText(item.week),
                               optionLabels: weekLabels)
            }
        } header: {
            HStack {
                Text(L10n.f("周期 %ld", index(of: item.wrappedValue) + 1))
                Spacer()
                if schedules.count > 1 {
                    Button(L10n.t("删除周期")) {
                        schedules.removeAll { $0.id == item.wrappedValue.id }
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
        }
    }

    /// 查找某个周期在数组中的下标（用于显示「周期 N」）
    private func index(of item: CreateCronjobView.ScheduleItem) -> Int {
        schedules.firstIndex { $0.id == item.id } ?? 0
    }

    /// 数字字段 Int ↔ String（输入钳制到原 Stepper 范围）
    private func intText(_ value: Binding<Int>, range: ClosedRange<Int>) -> Binding<String> {
        Binding<String>(
            get: { String(value.wrappedValue) },
            set: { text in
                guard let parsed = Int(text) else { return }
                value.wrappedValue = min(max(parsed, range.lowerBound), range.upperBound)
            }
        )
    }

    /// 星期 Int ↔ String（描边菜单用，键为 0...6）
    private func weekText(_ value: Binding<Int>) -> Binding<String> {
        Binding<String>(get: { String(value.wrappedValue) },
                        set: { value.wrappedValue = Int($0) ?? 0 })
    }

    private var weekLabels: [String: String] {
        var labels: [String: String] = [:]
        for w in 0..<7 { labels[String(w)] = weekDay(w) }
        return labels
    }

    private func weekDay(_ w: Int) -> String {
        let names = [L10n.t("周日"), L10n.t("周一"), L10n.t("周二"), L10n.t("周三"),
                     L10n.t("周四"), L10n.t("周五"), L10n.t("周六")]
        return names[w]
    }

    /// 预览各周期接下来 5 次执行时间（POST /cronjobs/next {spec}，抓包 2026-09-14）
    private func previewSchedules() async {
        isPreviewing = true
        previewResults = []
        previewFailedCount = 0
        defer { isPreviewing = false }
        let client = APIClient.shared(for: server)
        var results: [(spec: String, times: [String])] = []
        for item in schedules {
            let spec = item.cronSpec
            if let times: [String] = try? await client.send(
                path: APIEndpoint.cronjobsNext.path,
                body: CronjobNextRequest(spec: spec), as: [String].self) {
                results.append((spec, times))
            } else {
                previewFailedCount += 1
            }
        }
        previewResults = results
    }
}

// MARK: - 备份目录或文件：文件范围编辑页（形态 7.1）

/// 文件路径多行编辑：一行一个文件，右上角文件浏览器按钮可从服务端选择文件追加
struct CronjobFilesEditorView: View {
    let server: ServerConfig
    @Binding var text: String

    @State private var showFileBrowser = false

    var body: some View {
        Form {
            Section {
                OutlinedMultiLineField(label: L10n.t("文件路径"), lines: 7, text: $text)
            } footer: {
                Text(L10n.t("一行一个文件路径，可通过右上角文件浏览器从服务器选择"))
            }
        }
        .navigationTitle(L10n.t("选择文件"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFileBrowser = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel(L10n.t("从服务器选择文件"))
            }
        }
        .sheet(isPresented: $showFileBrowser) {
            FileBrowserView(server: server) { path in
                appendFile(path)
            }
        }
    }

    /// 追加一个文件路径（去重、去空行）
    private func appendFile(_ path: String) {
        var lines = nonEmptyLines()
        if !lines.contains(path) {
            lines.append(path)
        }
        text = lines.joined(separator: "\n")
    }

    private func nonEmptyLines() -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - 告警方式多选（告警分组入口行 → Sheet）

/// 告警方式多选 Sheet：勾选即回写 selection，关闭即确认（与备份参数多选同模式）
struct CronjobAlertMethodsPickerView: View {
    let methods: [AlertConfigItem]
    @Binding var selection: Set<Int>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if methods.isEmpty {
                    Section {
                        ContentUnavailableView(
                            L10n.t("暂无可用的告警方式"),
                            systemImage: "bell.slash",
                            description: Text(L10n.t("请先在告警通知的设置中配置发送方式"))
                        )
                        .padding(.vertical, 20)
                    }
                } else {
                    Section {
                        ForEach(methods) { method in
                            Button {
                                toggle(method.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selection.contains(method.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection.contains(method.id)
                                                         ? Color.accentColor : .secondary)
                                        .font(.title3)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(method.sendConfig.displayName
                                             ?? method.title
                                             ?? L10n.t("未知"))
                                            .foregroundStyle(.primary)
                                        Text(AlertSendType(rawValue: method.type ?? "")?.displayName
                                             ?? (method.type ?? ""))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        Text(L10n.t("可多选；任务失败达到告警次数后将通过所选方式通知"))
                    }
                }
            }
            .navigationTitle(L10n.t("告警方式"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完成")) { dismiss() }
                        .bold()
                }
            }
        }
        .bottomSheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func toggle(_ id: Int) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}

