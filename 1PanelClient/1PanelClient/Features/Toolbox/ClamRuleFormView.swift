//
//  ClamRuleFormView.swift
//  1PanelClient
//
//  ClamAV 扫描规则创建/编辑：名称 / 扫描目录 / 感染文件策略（隔离目录）/
//  定期扫描（每天|每周|每月 → specObj + cron spec）/ 告警（方式+次数）/
//  超时时间（数值+单位）/ 描述
//

import SwiftUI

struct ClamRuleFormView: View {
    /// 编辑模式传入已有规则；添加模式传 nil
    let editing: ClamItem?
    @ObservedObject var vm: ClamViewModel
    @Environment(\.dismiss) private var dismiss

    // 基本信息
    @State private var name = ""
    @State private var desc = ""

    // 扫描目录 / 感染文件策略
    @State private var path = ""
    @State private var strategy = "none"
    @State private var quarantineDir = ""

    // 定期扫描
    @State private var hasSpec = false
    @State private var specType = "perDay"
    @State private var week = 1
    @State private var day = 3
    @State private var hour = 1
    @State private var minute = 30

    // 告警
    @State private var hasAlert = false
    @State private var alertMethodID = 0
    @State private var alertCount = 3
    @State private var alertConfigs: [AlertConfigItem] = []

    // 超时
    @State private var timeoutText = "300"
    /// 超时单位（s/m/h，随数值一起提交，后端按单位换算）
    @State private var timeoutUnitValue = "m"
    private let timeoutUnitOptions = ["s", "m", "h"]

    @State private var isSaving = false
    @State private var didFill = false

    private let client: APIClient

    init(server: ServerConfig, editing: ClamItem?, vm: ClamViewModel) {
        self.editing = editing
        self.vm = vm
        self.client = APIClient.shared(for: server)
    }

    private var isEditing: Bool { editing != nil }
    private var needsQuarantine: Bool { strategy == "move" || strategy == "copy" }

    /// UI 单位固定分钟，提交换算秒
    private var timeoutSeconds: Int {
        (Int(timeoutText) ?? 0) * Self.timeoutUnitSeconds(timeoutUnitValue)
    }

    /// 单位 → 秒
    private static func timeoutUnitSeconds(_ unit: String) -> Int {
        switch unit {
        case "s": return 1
        case "h": return 3600
        default:  return 60
        }
    }

    private var canSubmit: Bool {
        guard !name.isEmpty, path.hasPrefix("/"), !isSaving else { return false }
        if needsQuarantine && !quarantineDir.hasPrefix("/") { return false }
        if hasAlert && alertMethodID == 0 { return false }
        // 超时无计划任务也需为正数（服务端默认 300s，前端提交 0 会导致规则立即超时）
        guard let t = Int(timeoutText), t > 0 else { return false }
        return true
    }

    var body: some View {
        Form {
            basicSection
            scanSection
            scheduleSection
            alertSection
            timeoutSection
            // 描述统一置底（形态 7.1，默认 1 行）
            descSection
        }
        .navigationTitle(isEditing ? L10n.t("编辑规则") : L10n.t("添加规则"))
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
            await loadAlertConfigs()
            fillIfEditing()
            reconcileAlertMethod()
        }
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        Section {
            OutlinedTextField(label: L10n.t("名称"), text: $name)
                .disabled(isEditing)
        } header: {
            SectionLabel(title: L10n.t("基本信息"), systemImage: "info.circle")
        } footer: {
            if isEditing {
                Text(L10n.t("名称不可修改"))
            }
        }
    }

    /// 描述（置底）
    private var descSection: some View {
        Section {
            OutlinedMultiLineField(label: L10n.t("描述"), prompt: L10n.t("可选"),
                                   lines: 1, text: $desc)
        }
    }

    // MARK: - 扫描设置

    private var scanSection: some View {
        Section {
            // 扫描目录：目录浏览图标内嵌描边框右侧（可手输 + 浏览回填）
            FilePathBrowseRow(title: L10n.t("扫描目录"), path: $path, client: vm.client)

            OutlinedPicker(label: L10n.t("感染文件策略"),
                           options: ["none", "remove", "move", "copy"],
                           selection: $strategy,
                           optionLabels: ["none": L10n.t("不操作"), "remove": L10n.t("删除"),
                                          "move": L10n.t("移动"), "copy": L10n.t("复制")])

            if needsQuarantine {
                FilePathBrowseRow(title: L10n.t("隔离目录"), path: $quarantineDir, client: vm.client)
            }
        } header: {
            SectionLabel(title: L10n.t("扫描设置"), systemImage: "magnifyingglass")
        } footer: {
            Text(L10n.t("移动或复制策略需指定隔离目录，用于存放扫描发现的感染文件"))
        }
    }

    // MARK: - 定期扫描

    private var scheduleSection: some View {
        Section {
            Toggle(L10n.t("定期扫描"), isOn: $hasSpec)

            if hasSpec {
                OutlinedPicker(label: L10n.t("周期"),
                               options: ["perMonth", "perWeek", "perDay"],
                               selection: $specType,
                               optionLabels: ["perMonth": L10n.t("每月"),
                                              "perWeek": L10n.t("每周"),
                                              "perDay": L10n.t("每天")])

                if specType == "perWeek" {
                    OutlinedPicker(label: L10n.t("星期"),
                                   options: (1...7).map(String.init),
                                   selection: weekText,
                                   optionLabels: Dictionary(uniqueKeysWithValues:
                                       (1...7).map { (String($0), weekdayName($0)) }))
                }
                if specType == "perMonth" {
                    OutlinedPicker(label: L10n.t("几号"),
                                   options: (1...31).map(String.init),
                                   selection: dayText)
                }

                OutlinedPicker(label: L10n.t("小时"),
                               options: (0..<24).map(String.init),
                               selection: hourText)
                OutlinedPicker(label: L10n.t("分钟"),
                               options: (0..<60).map(String.init),
                               selection: minuteText)
            }
        } header: {
            SectionLabel(title: L10n.t("定期扫描"), systemImage: "clock")
        } footer: {
            if hasSpec {
                Text(L10n.f("Cron：%@", generatedSpec))
            }
        }
    }

    private func weekdayName(_ w: Int) -> String {
        switch w {
        case 1: return L10n.t("周一")
        case 2: return L10n.t("周二")
        case 3: return L10n.t("周三")
        case 4: return L10n.t("周四")
        case 5: return L10n.t("周五")
        case 6: return L10n.t("周六")
        default: return L10n.t("周日")
        }
    }

    /// 5 段 cron：分 时 日 月 周
    private var generatedSpec: String {
        switch specType {
        case "perWeek":  return "\(minute) \(hour) * * \(week)"
        case "perMonth": return "\(minute) \(hour) \(day) * *"
        default:         return "\(minute) \(hour) * * *"
        }
    }

    // MARK: - 告警

    private var alertSection: some View {
        Section {
            Toggle(L10n.t("扫描告警"), isOn: $hasAlert)

            if hasAlert {
                if alertConfigs.isEmpty {
                    Text(L10n.t("请先在「告警通知」中配置发送方式"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    OutlinedPicker(label: L10n.t("告警方式"),
                                   options: alertMethodOptionKeys,
                                   selection: alertMethodText,
                                   optionLabels: alertMethodOptionLabels)
                    OutlinedUnitField(label: L10n.t("告警次数"), unit: L10n.t("次"),
                                      text: alertCountText, range: 1...99)
                }
            }
        } header: {
            SectionLabel(title: L10n.t("扫描告警"), systemImage: "bell.badge")
        } footer: {
            if hasAlert {
                Text(L10n.t("扫描到感染文件时通过所选方式发送通知"))
            }
        }
    }

    // MARK: - 超时

    /// 告警次数 Int ↔ String（范围钳制由 OutlinedUnitField 失焦归位负责）
    private var alertCountText: Binding<String> {
        Binding<String>(get: { String(alertCount) },
                        set: { text in
            if let parsed = Int(text) { alertCount = parsed }
        })
    }

    // 定期扫描数值选项 Int ↔ String（OutlinedPicker 用 String 键）
    private var weekText: Binding<String> {
        Binding<String>(get: { String(week) }, set: { week = Int($0) ?? week })
    }

    private var dayText: Binding<String> {
        Binding<String>(get: { String(day) }, set: { day = Int($0) ?? day })
    }

    private var hourText: Binding<String> {
        Binding<String>(get: { String(hour) }, set: { hour = Int($0) ?? hour })
    }

    private var minuteText: Binding<String> {
        Binding<String>(get: { String(minute) }, set: { minute = Int($0) ?? minute })
    }

    /// 告警方式选项（0=请选择）
    private var alertMethodOptionKeys: [String] {
        ["0"] + alertConfigs.map { String($0.id) }
    }

    private var alertMethodOptionLabels: [String: String] {
        var labels = ["0": L10n.t("请选择")]
        for config in alertConfigs {
            labels[String(config.id)] = config.sendConfig.displayName ?? config.type ?? "—"
        }
        return labels
    }

    private var alertMethodText: Binding<String> {
        Binding<String>(
            get: { String(alertMethodID) },
            set: { alertMethodID = Int($0) ?? 0 }
        )
    }

    private var timeoutSection: some View {
        Section {
            // 数值 + 单位菜单（提交携带单位，后端换算）
            OutlinedUnitField(label: L10n.t("超时时间"), unit: "",
                              text: $timeoutText, range: 1...8760)
            OutlinedPicker(label: L10n.t("超时单位"),
                           options: timeoutUnitOptions, selection: $timeoutUnitValue,
                           optionLabels: ["s": L10n.t("秒"),
                                          "m": L10n.t("分钟"),
                                          "h": L10n.t("小时")])
        } header: {
            SectionLabel(title: L10n.t("超时时间"), systemImage: "hourglass")
        } footer: {
            Text(L10n.f("超时后自动终止扫描，当前为 %ld 秒", timeoutSeconds))
        }
    }

    // MARK: - 数据加载与回填

    private func loadAlertConfigs() async {
        guard alertConfigs.isEmpty else { return }
        do {
            let resp: PageResponse<AlertConfigItem> = try await client.send(
                path: APIEndpoint.alertConfigSearch.path,
                body: AlertConfigSearchRequest(),
                as: PageResponse<AlertConfigItem>.self)
            alertConfigs = resp.items ?? []
        } catch {
            alertConfigs = []
        }
    }

    private func fillIfEditing() {
        guard let rule = editing, !didFill else { return }
        didFill = true
        name = rule.name
        desc = rule.description ?? ""
        path = rule.path
        strategy = rule.infectedStrategy ?? "none"
        quarantineDir = rule.infectedDir ?? ""

        // cron 回填：周位非 * → perWeek；日位非 * → perMonth；否则 perDay
        if let spec = rule.spec, !spec.isEmpty {
            hasSpec = true
            let parts = spec.split(separator: " ").map(String.init)
            if parts.count == 5, let m = Int(parts[0]), let h = Int(parts[1]) {
                minute = m
                hour = h
                if parts[4] != "*", let w = Int(parts[4]) {
                    specType = "perWeek"
                    week = min(max(w, 1), 7)
                } else if parts[2] != "*", let d = Int(parts[2]) {
                    specType = "perMonth"
                    day = min(max(d, 1), 31)
                } else {
                    specType = "perDay"
                }
            }
        }

        // 超时秒数反推为分钟（向上取整，不足 1 分钟按 1 计）
        if let seconds = rule.timeout, seconds > 0 {
            // 秒 → 数值+单位：整除取大单位（原值可整除时往返无损）
            if seconds % 3600 == 0, seconds >= 3600 {
                timeoutUnitValue = "h"
                timeoutText = String(seconds / 3600)
            } else if seconds % 60 == 0 {
                timeoutUnitValue = "m"
                timeoutText = String(seconds / 60)
            } else {
                timeoutUnitValue = "s"
                timeoutText = String(max(1, seconds))
            }
        }

        if let method = rule.alertMethod, !method.isEmpty, let id = Int(method) {
            hasAlert = true
            alertMethodID = id
            alertCount = rule.alertCount ?? 3
        }
    }

    /// 回填的告警方式已不存在（配置被删 / 列表加载失败）时重置，
    /// 避免 Picker 无效 selection 告警与保存提交失效 id
    private func reconcileAlertMethod() {
        guard hasAlert, alertMethodID != 0 else { return }
        if !alertConfigs.contains(where: { $0.id == alertMethodID }) {
            alertMethodID = 0
        }
    }

    // MARK: - 保存

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let method = hasAlert ? String(alertMethodID) : ""
        let request = ClamUpsertRequest(
            id: editing?.id,
            createdAt: editing?.createdAt,
            status: editing?.status,
            lastRecordStatus: editing?.lastRecordStatus,
            lastRecordTime: editing?.lastRecordTime,
            description: desc.isEmpty ? nil : desc,
            alertCount: hasAlert ? alertCount : (editing?.alertCount ?? 0),
            infectedStrategy: strategy,
            infectedDir: needsQuarantine ? quarantineDir : (editing?.infectedDir ?? ""),
            specObj: ClamSpecObj(
                specType: specType,
                week: week,
                day: day,
                hour: hour,
                minute: minute,
                second: 30),
            timeoutItem: Int(timeoutText) ?? 0,
            timeoutUnit: timeoutUnitValue,
            hasAlert: hasAlert,
            alertMethodItems: hasAlert && alertMethodID != 0 ? [method] : [],
            alertTitle: hasAlert ? L10n.f("病毒扫描「 %@ 」任务检测到感染文件告警", name) : "",
            name: name,
            path: path,
            timeout: timeoutSeconds,
            spec: hasSpec ? generatedSpec : "",
            alertMethod: method,
            hasSpec: hasSpec ? true : nil)

        let ok: Bool
        if editing != nil {
            ok = await vm.updateRule(req: request)
        } else {
            ok = await vm.createRule(req: request)
        }
        if ok { dismiss() }
    }
}
