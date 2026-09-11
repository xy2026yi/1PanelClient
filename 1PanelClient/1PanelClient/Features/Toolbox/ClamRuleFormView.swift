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
    @State private var showDirPicker = false
    @State private var strategy = "none"
    @State private var quarantineDir = ""
    @State private var showQuarantinePicker = false

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
    @State private var timeoutUnit = "h"
    @State private var timeoutText = "5"

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

    private var timeoutSeconds: Int {
        let value = Int(timeoutText) ?? 0
        let multiplier: Int
        switch timeoutUnit {
        case "h": multiplier = 3600
        case "m": multiplier = 60
        default:  multiplier = 1
        }
        return value * multiplier
    }

    private var canSubmit: Bool {
        guard !name.isEmpty, path.hasPrefix("/"), !isSaving else { return false }
        if needsQuarantine && !quarantineDir.hasPrefix("/") { return false }
        if hasAlert && alertMethodID == 0 { return false }
        if hasSpec {
            guard let t = Int(timeoutText), t > 0 else { return false }
        }
        return true
    }

    var body: some View {
        Form {
            basicSection
            scanSection
            scheduleSection
            alertSection
            timeoutSection
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
        }
        .sheet(isPresented: $showDirPicker) {
            // 用宿主 VM 的 client：避免多机切换瞬间读到别的服务器的目录
            DirectoryPickerSheet(client: vm.client) { picked in
                path = picked
            }
        }
        .sheet(isPresented: $showQuarantinePicker) {
            DirectoryPickerSheet(client: vm.client) { picked in
                quarantineDir = picked
            }
        }
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        Section {
            TextField(L10n.t("名称"), text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(isEditing)
            TextField(L10n.t("可选描述"), text: $desc, axis: .vertical)
                .lineLimit(1...3)
        } header: {
            SectionLabel(title: L10n.t("基本信息"), systemImage: "info.circle")
        } footer: {
            if isEditing {
                Text(L10n.t("名称不可修改"))
            }
        }
    }

    // MARK: - 扫描设置

    private var scanSection: some View {
        Section {
            HStack {
                TextField(L10n.t("扫描目录"), text: $path)
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

            Picker(L10n.t("感染文件策略"), selection: $strategy) {
                Text(L10n.t("不操作")).tag("none")
                Text(L10n.t("删除")).tag("remove")
                Text(L10n.t("移动")).tag("move")
                Text(L10n.t("复制")).tag("copy")
            }

            if needsQuarantine {
                HStack {
                    TextField(L10n.t("隔离目录"), text: $quarantineDir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        showQuarantinePicker = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.t("浏览目录"))
                }
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
                Picker(L10n.t("周期"), selection: $specType) {
                    Text(L10n.t("每月")).tag("perMonth")
                    Text(L10n.t("每周")).tag("perWeek")
                    Text(L10n.t("每天")).tag("perDay")
                }
                .pickerStyle(.segmented)

                if specType == "perWeek" {
                    Picker(L10n.t("星期"), selection: $week) {
                        ForEach(1...7, id: \.self) { w in
                            Text(weekdayName(w)).tag(w)
                        }
                    }
                }
                if specType == "perMonth" {
                    Picker(L10n.t("几号"), selection: $day) {
                        ForEach(1...31, id: \.self) { d in
                            Text("\(d)").tag(d)
                        }
                    }
                }

                Picker(L10n.t("小时"), selection: $hour) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(String(format: "%02d", h)).tag(h)
                    }
                }
                Picker(L10n.t("分钟"), selection: $minute) {
                    ForEach(0..<60, id: \.self) { m in
                        Text(String(format: "%02d", m)).tag(m)
                    }
                }
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
                    Picker(L10n.t("告警方式"), selection: $alertMethodID) {
                        Text(L10n.t("请选择")).tag(0)
                        ForEach(alertConfigs) { config in
                            Text(config.sendConfig.displayName ?? config.type ?? "—").tag(config.id)
                        }
                    }
                    Stepper(value: $alertCount, in: 1...99) {
                        HStack {
                            Text(L10n.t("告警次数"))
                            Spacer()
                            Text("\(alertCount)").foregroundStyle(.secondary)
                        }
                    }
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

    private var timeoutSection: some View {
        Section {
            HStack {
                TextField(L10n.t("超时时间"), text: $timeoutText)
                    .keyboardType(.numberPad)
                Picker("", selection: $timeoutUnit) {
                    Text(L10n.t("小时")).tag("h")
                    Text(L10n.t("分钟")).tag("m")
                    Text(L10n.t("秒")).tag("s")
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
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

        // 超时秒数反推：整小时 → 小时；整分钟 → 分钟；否则秒
        if let seconds = rule.timeout, seconds > 0 {
            if seconds % 3600 == 0 {
                timeoutUnit = "h"
                timeoutText = String(seconds / 3600)
            } else if seconds % 60 == 0 {
                timeoutUnit = "m"
                timeoutText = String(seconds / 60)
            } else {
                timeoutUnit = "s"
                timeoutText = String(seconds)
            }
        }

        if let method = rule.alertMethod, !method.isEmpty, let id = Int(method) {
            hasAlert = true
            alertMethodID = id
            alertCount = rule.alertCount ?? 3
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
            timeoutUnit: timeoutUnit,
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
