//
//  AlertEditView.swift
//  1PanelClient
//
//  告警规则创建 / 编辑表单（面板密码到期 / 证书到期 / 网站到期 / SSH·面板登录异常）
//

import SwiftUI

struct AlertEditView: View {
    @ObservedObject var vm: AlertViewModel
    /// 编辑模式时传入已有规则；创建模式传 nil
    let editing: AlertRule?
    @Environment(\.dismiss) private var dismiss

    @State private var type: AlertType = .panelPwdEndTime
    /// true = 所有对象 / 所有发送方式
    @State private var projectAll = true
    @State private var selectedProjectID: Int?
    @State private var sendMethodAll = true
    @State private var selectedConfigID: Int?
    /// 到期类型：剩余天数；登录类型：时间窗口（分钟）
    @State private var cycle = 15
    /// 登录类型：窗口内失败次数；CPU/内存/负载/磁盘：百分比阈值
    @State private var failCount = 3
    @State private var threshold = 80
    /// 磁盘告警监测类型：1=占用磁盘（默认阈值 30%）2=占用百分比（默认阈值 80%）
    @State private var diskMonitorKind = 2
    @State private var selectedDiskPath: String?
    /// 告警次数（最多发送次数）
    @State private var sendCount = 3
    /// 登录类型：IP 白名单（每行一个，支持 CIDR）
    @State private var whitelist = ""
    @State private var enabled = true
    @State private var didFill = false

    private var isEditing: Bool { editing != nil }

    /// 可用发送方式（创建告警的前置条件）
    private var availableConfigs: [AlertConfigItem] { vm.configs }

    var body: some View {
        Form {
            basicSection
            if type.needsProject { projectSection }
            if type.isDisk { diskSection }
            conditionSection
            if type.isLoginType { whitelistSection }
            methodSection
            if isEditing { statusSection }
        }
        .navigationTitle(isEditing ? L10n.t("编辑告警") : L10n.t("创建告警"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? L10n.t("保存") : L10n.t("创建")) {
                    if let req = buildRequest() {
                        Task {
                            // 成功后自动返回列表，Toast 在列表页展示
                            if await vm.upsert(req) { dismiss() }
                        }
                    }
                }
                .disabled(buildRequest() == nil)
            }
        }
        .onAppear { fillIfEditing() }
        .onChange(of: type) { _, newType in
            // 切换类型后恢复该类型默认值
            cycle = newType.defaultCycle
            projectAll = true
            selectedProjectID = nil
            selectedDiskPath = nil
            threshold = newType.defaultThreshold
            diskMonitorKind = 2
            Task { await vm.loadOptions(for: newType) }
        }
        .onChange(of: diskMonitorKind) { _, kind in
            // 占用磁盘默认 30%，占用百分比默认 80%（对齐官方默认值）
            threshold = kind == 1 ? 30 : 80
        }
        .task { await vm.loadOptions(for: type) }
    }

    // MARK: - 基本信息

    private var basicSection: some View {
        Section {
            if isEditing {
                LabeledContent(L10n.t("告警类型"), value: editing?.alertType.displayName ?? (editing?.type ?? L10n.t("未知")))
            } else {
                OutlinedPicker(label: L10n.t("告警类型"), options: AlertType.creatable,
                               selection: $type) { $0.displayName }
            }
        } header: {
            Text(L10n.t("基本信息"))
        }
    }

    // MARK: - 告警对象（证书 / 网站）

    private var projectSection: some View {
        Section {
            OutlinedPicker(label: type == .ssl ? L10n.t("证书") : L10n.t("网站"),
                           options: ["all", "custom"], selection: projectAllText,
                           optionLabels: ["all": L10n.t("所有"), "custom": L10n.t("指定")])

            if !projectAll {
                if vm.isLoadingOptions {
                    HStack {
                        Spacer()
                        LoadingStateView()
                        Spacer()
                    }
                } else {
                    OutlinedPicker(label: L10n.t("选择对象"),
                                   options: objectOptionKeys, selection: objectText,
                                   optionLabels: objectOptionLabels)
                }
            }
        } header: {
            Text(L10n.t("告警对象"))
        } footer: {
            if !projectAll && !vm.isLoadingOptions {
                Text(L10n.t("面板将以剩余天数为准，在到期前触发告警"))
            }
        }
    }

    /// 对象显示名（证书取 primaryDomain，网站取 primaryDomain/alias）
    private func projectName(id: Int) -> String {
        if type == .ssl {
            return vm.sslOptions.first(where: { $0.id == id })?.domain ?? L10n.t("未知")
        }
        return vm.websiteOptions.first(where: { $0.id == id })?.domain ?? L10n.t("未知")
    }

    // MARK: - 磁盘选择（磁盘告警）

    private var diskSection: some View {
        Section {
            OutlinedPicker(label: L10n.t("磁盘"),
                           options: ["all", "custom"], selection: projectAllText,
                           optionLabels: ["all": L10n.t("所有"), "custom": L10n.t("指定")])

            if !projectAll {
                if vm.isLoadingOptions {
                    HStack {
                        Spacer()
                        LoadingStateView()
                        Spacer()
                    }
                } else {
                    OutlinedPicker(label: L10n.t("选择磁盘"),
                                   options: diskOptionKeys, selection: diskText,
                                   optionLabels: diskOptionLabels)
                }
            }
        } header: {
            Text(L10n.t("磁盘信息"))
        } footer: {
            if !projectAll && !vm.isLoadingOptions {
                Text(L10n.t("选择需要监控的挂载目录"))
            }
        }
    }

    private func diskLabel(_ disk: AlertDiskOption) -> String {
        if let fs = disk.type, !fs.isEmpty {
            return "\(disk.path)（\(fs)）"
        }
        return disk.path
    }

    // MARK: - 触发条件

    /// Stepper → 描边数字+单位：Int ↔ String（输入钳制在原 Stepper 范围内）
    private func unitText(_ value: Binding<Int>, range: ClosedRange<Int>) -> Binding<String> {
        Binding<String>(
            get: { String(value.wrappedValue) },
            set: { text in
                let parsed = Int(text) ?? value.wrappedValue
                value.wrappedValue = min(max(parsed, range.lowerBound), range.upperBound)
            }
        )
    }

    /// 磁盘监测类型 Int ↔ String（OutlinedPicker 用 String）
    private var diskMonitorKindBinding: Binding<String> {
        Binding<String>(
            get: { String(diskMonitorKind) },
            set: { diskMonitorKind = Int($0) ?? 1 }
        )
    }

    /// 所有/指定 Bool ↔ String（OutlinedPicker 用；证书/网站与磁盘共用 projectAll）
    private var projectAllText: Binding<String> {
        Binding<String>(
            get: { projectAll ? "all" : "custom" },
            set: { projectAll = $0 == "all" }
        )
    }

    private var sendMethodAllText: Binding<String> {
        Binding<String>(
            get: { sendMethodAll ? "all" : "custom" },
            set: { sendMethodAll = $0 == "all" }
        )
    }

    /// 选择对象选项（0=请选择；证书/网站按告警类型二选一）
    private var objectOptionKeys: [String] {
        let ids = type == .ssl ? vm.sslOptions.map(\.id) : vm.websiteOptions.map(\.id)
        return ["0"] + ids.map(String.init)
    }

    private var objectOptionLabels: [String: String] {
        let ids = type == .ssl ? vm.sslOptions.map(\.id) : vm.websiteOptions.map(\.id)
        var labels = ["0": L10n.t("请选择")]
        for id in ids { labels[String(id)] = projectName(id: id) }
        return labels
    }

    private var objectText: Binding<String> {
        Binding<String>(
            get: { selectedProjectID.map(String.init) ?? "0" },
            set: { selectedProjectID = $0 == "0" ? nil : Int($0) }
        )
    }

    /// 选择磁盘选项（空串=请选择，键为挂载路径）
    private var diskOptionKeys: [String] {
        [""] + vm.diskOptions.map(\.path)
    }

    private var diskOptionLabels: [String: String] {
        var labels = ["": L10n.t("请选择")]
        for disk in vm.diskOptions { labels[disk.path] = diskLabel(disk) }
        return labels
    }

    private var diskText: Binding<String> {
        Binding<String>(
            get: { selectedDiskPath ?? "" },
            set: { selectedDiskPath = $0.isEmpty ? nil : $0 }
        )
    }

    /// 发送方式选项（0=请选择）
    private var sendConfigOptionKeys: [String] {
        ["0"] + availableConfigs.map { String($0.id) }
    }

    private var sendConfigOptionLabels: [String: String] {
        var labels = ["0": L10n.t("请选择")]
        for config in availableConfigs {
            labels[String(config.id)] = config.sendConfig.displayName ?? (config.type ?? L10n.t("未知"))
        }
        return labels
    }

    private var sendConfigText: Binding<String> {
        Binding<String>(
            get: { selectedConfigID.map(String.init) ?? "0" },
            set: { selectedConfigID = $0 == "0" ? nil : Int($0) }
        )
    }

    private var conditionSection: some View {
        Section {
            if type.isLoginType {
                OutlinedUnitField(label: L10n.t("时间窗口"), unit: L10n.t("分钟"),
                                  text: unitText($cycle, range: 1...1440))
                OutlinedUnitField(label: L10n.t("失败次数"), unit: L10n.t("次"),
                                  text: unitText($failCount, range: 1...999))
            } else if type.isPercentType {
                // 指定时间不可修改（固定为监控采集间隔 5 分钟）：形态 1 只读框 + 小锁
                OutlinedShape(label: L10n.t("指定时间"), isFocused: false,
                              hasValue: true,
                              trailing: {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }) {
                    Text(L10n.t("5 分钟"))
                        .lineLimit(1)
                }
                OutlinedUnitField(label: L10n.t("平均使用率超过"), unit: "%",
                                  text: unitText($threshold, range: 1...100))
            } else if type.isDisk {
                OutlinedPicker(label: L10n.t("监测类型"), options: ["1", "2"],
                               selection: diskMonitorKindBinding,
                               optionLabels: ["1": L10n.t("占用磁盘"),
                                              "2": L10n.t("占用百分比")])
                OutlinedUnitField(label: L10n.t("使用超过"), unit: "%",
                                  text: unitText($threshold, range: 1...100))
            } else if !type.isSimpleNotice {
                OutlinedUnitField(label: L10n.t("剩余天数"), unit: L10n.t("天"),
                                  text: unitText($cycle, range: 1...90))
            }
            OutlinedUnitField(label: L10n.t("告警次数"), unit: L10n.t("次"),
                              text: unitText($sendCount, range: 1...99))
        } header: {
            Text(L10n.t("触发条件"))
        } footer: {
            Text(conditionFooter)
        }
    }

    private var conditionFooter: String {
        switch type {
        case .sshLogin, .panelLogin:
            return L10n.t("窗口时间内登录失败达到次数即触发告警")
        case .cpu, .memory, .load:
            return L10n.t("时间窗口固定为监控采集间隔 5 分钟，平均使用率超过阈值即触发")
        case .disk:
            return L10n.t("按监测类型统计磁盘使用，超过阈值即触发")
        case .panelUpdate:
            return L10n.t("面板有新版本发布时通知")
        default:
            return L10n.t("证书 / 网站 / 密码到期前，每天检查并按告警次数发送")
        }
    }

    // MARK: - IP 白名单（登录异常类型）

    private var whitelistSection: some View {
        Section {
            OutlinedMultiLineField(label: L10n.t("IP 白名单"), prompt: "1.2.3.4",
                                   text: $whitelist)
        } header: {
            SectionLabel(title: L10n.t("IP 白名单"), systemImage: "checkmark.shield")
        } footer: {
            Text(L10n.t("白名单内的 IP 登录失败不会触发告警，每行一个，支持 IP 或 CIDR 网段"))
        }
    }

    // MARK: - 告警方式

    private var methodSection: some View {
        Section {
            if availableConfigs.isEmpty {
                Label(L10n.t("请先在「设置」中配置发送方式"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                OutlinedPicker(label: L10n.t("发送至"),
                               options: ["all", "custom"], selection: sendMethodAllText,
                               optionLabels: ["all": L10n.t("所有"), "custom": L10n.t("指定")])

                if !sendMethodAll {
                    OutlinedPicker(label: L10n.t("发送方式"),
                                   options: sendConfigOptionKeys, selection: sendConfigText,
                                   optionLabels: sendConfigOptionLabels)
                }
            }
        } header: {
            Text(L10n.t("告警方式"))
        } footer: {
            Text(availableConfigs.isEmpty ? L10n.t("告警需要至少一个可用的发送方式") : L10n.t("触发告警时通过所选方式通知"))
        }
    }

    // MARK: - 状态（仅编辑）

    private var statusSection: some View {
        Section {
            Toggle(L10n.t("启用告警"), isOn: $enabled)
        }
    }

    // MARK: - 编辑预填

    private func fillIfEditing() {
        guard let rule = editing, !didFill else { return }
        didFill = true
        if let t = rule.type, AlertType(rawValue: t) != .unknown {
            type = AlertType(rawValue: t) ?? .panelPwdEndTime
        }
        let project = rule.project ?? ""
        projectAll = project.isEmpty || project == "all"
        selectedProjectID = projectAll ? nil : Int(project)
        cycle = rule.cycle ?? type.defaultCycle
        failCount = rule.count ?? 3
        threshold = rule.count ?? type.defaultThreshold
        diskMonitorKind = (type.isDisk && rule.cycle == 1) ? 1 : 2
        selectedDiskPath = (type.isDisk && !projectAll) ? project : nil
        sendCount = rule.sendCount ?? 3
        whitelist = rule.advancedParams ?? ""
        enabled = rule.isEnabled
        // 规则记录不含 sendMethod：method 与某个发送方式 id 匹配则视为指定，否则视为所有
        if let m = rule.method, let id = Int(m), availableConfigs.contains(where: { $0.id == id }) {
            sendMethodAll = false
            selectedConfigID = id
        } else {
            sendMethodAll = true
            selectedConfigID = nil
        }
    }

    // MARK: - 请求构造

    /// 生成的告警标题（对齐官方自动命名规则）
    private var generatedTitle: String? {
        switch type {
        case .panelPwdEndTime:
            return L10n.t("面板密码到期告警")
        case .cpu:
            return L10n.t("CPU 占用过高告警")
        case .memory:
            return L10n.t("内存占用过高告警")
        case .load:
            return L10n.t("负载占用过高告警")
        case .disk:
            if projectAll { return L10n.t("磁盘占用过高告警") }
            guard let path = selectedDiskPath else { return nil }
            return L10n.f("挂载目录「%@」的磁盘占用过高告警", path)
        case .sshLogin:
            return L10n.t("SSH 登录异常告警")
        case .panelLogin:
            return L10n.t("面板登录异常告警")
        case .ssl:
            if projectAll { return L10n.t("所有网站证书到期告警") }
            guard let id = selectedProjectID else { return nil }
            return L10n.f("网站「 %@ 」证书到期告警", projectName(id: id))
        case .siteEndTime:
            if projectAll { return L10n.t("所有网站到期告警") }
            guard let id = selectedProjectID else { return nil }
            return L10n.f("网站「 %@ 」到期告警", projectName(id: id))
        case .panelUpdate:
            return L10n.t("面板新版本提醒")
        case .unknown:
            return nil
        }
    }

    private func buildRequest() -> AlertUpsertRequest? {
        guard let title = generatedTitle else { return nil }
        guard !availableConfigs.isEmpty else { return nil }
        guard type != .unknown else { return nil }

        // method 必填：所有方式时携带全部可用 id（逗号分隔），指定时为单个 id（对齐官方请求）
        let method: String
        let sendMethod: [String]
        if sendMethodAll {
            method = availableConfigs.map { String($0.id) }.joined(separator: ",")
            sendMethod = ["__all__"]
        } else if let id = selectedConfigID {
            method = String(id)
            sendMethod = [String(id)]
        } else {
            return nil
        }

        let project: String
        switch type {
        case .panelPwdEndTime:
            project = ""
        case .sshLogin, .panelLogin, .cpu, .memory, .load, .panelUpdate:
            project = "all"
        case .ssl, .siteEndTime:
            if projectAll {
                project = "all"
            } else if let id = selectedProjectID {
                project = String(id)
            } else {
                return nil
            }
        case .disk:
            if projectAll {
                project = "all"
            } else if let path = selectedDiskPath {
                project = path
            } else {
                return nil
            }
        case .unknown:
            return nil
        }

        // cycle/count 语义随类型变化：百分比类 cycle 固定 5；磁盘 cycle 为监测类型；面板更新均为 0
        let finalCycle: Int
        let finalCount: Int
        switch type {
        case .cpu, .memory, .load:
            finalCycle = 5
            finalCount = threshold
        case .disk:
            finalCycle = diskMonitorKind
            finalCount = threshold
        case .panelUpdate:
            finalCycle = 0
            finalCount = 0
        default:
            finalCycle = cycle
            finalCount = type.isLoginType ? failCount : 0
        }

        var req = AlertUpsertRequest(
            id: editing?.id,
            type: type.rawValue,
            cycle: finalCycle,
            count: finalCount,
            sendCount: sendCount,
            method: method,
            project: project,
            status: enabled ? "Enable" : "Disable",
            title: title,
            sendMethod: sendMethod
        )
        if type.isLoginType {
            let lines = whitelist
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            req.advancedParams = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        } else if isEditing {
            // 编辑非登录类型时回传空串，对齐官方更新请求
            req.advancedParams = ""
        }
        if type == .panelUpdate {
            req.subType = editing?.subType ?? "website"
        }
        if let rule = editing {
            req.createUser = rule.createUser
            req.updateUser = rule.updateUser
            req.createdAt = rule.createdAt
            req.updatedAt = rule.updatedAt
        }
        return req
    }
}
