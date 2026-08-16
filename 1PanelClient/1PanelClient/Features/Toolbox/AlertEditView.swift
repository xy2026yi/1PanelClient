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
        .navigationTitle(isEditing ? "编辑告警" : "创建告警")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("确认") {
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
                LabeledContent("告警类型", value: editing?.alertType.displayName ?? (editing?.type ?? "未知"))
            } else {
                Picker("告警类型", selection: $type) {
                    ForEach(AlertType.creatable) { t in
                        Text(t.displayName).tag(t)
                    }
                }
            }
        } header: {
            Text("基本信息")
        }
    }

    // MARK: - 告警对象（证书 / 网站）

    private var projectSection: some View {
        Section {
            Picker(type == .ssl ? "证书" : "网站", selection: $projectAll) {
                Text("所有").tag(true)
                Text("指定").tag(false)
            }
            .pickerStyle(.segmented)

            if !projectAll {
                if vm.isLoadingOptions {
                    HStack {
                        Spacer()
                        ProgressView("加载中…")
                        Spacer()
                    }
                } else {
                    Picker("选择对象", selection: $selectedProjectID) {
                        Text("请选择").tag(Int?.none)
                        ForEach(type == .ssl ? vm.sslOptions.map(\.id) : vm.websiteOptions.map(\.id), id: \.self) { id in
                            Text(projectName(id: id)).tag(Int?.some(id))
                        }
                    }
                }
            }
        } header: {
            Text("告警对象")
        } footer: {
            if !projectAll && !vm.isLoadingOptions {
                Text("面板将以剩余天数为准，在到期前触发告警")
            }
        }
    }

    /// 对象显示名（证书取 primaryDomain，网站取 primaryDomain/alias）
    private func projectName(id: Int) -> String {
        if type == .ssl {
            return vm.sslOptions.first(where: { $0.id == id })?.domain ?? "未知"
        }
        return vm.websiteOptions.first(where: { $0.id == id })?.domain ?? "未知"
    }

    // MARK: - 磁盘选择（磁盘告警）

    private var diskSection: some View {
        Section {
            Picker("磁盘", selection: $projectAll) {
                Text("所有").tag(true)
                Text("指定").tag(false)
            }
            .pickerStyle(.segmented)

            if !projectAll {
                if vm.isLoadingOptions {
                    HStack {
                        Spacer()
                        ProgressView("加载中…")
                        Spacer()
                    }
                } else {
                    Picker("选择磁盘", selection: $selectedDiskPath) {
                        Text("请选择").tag(String?.none)
                        ForEach(vm.diskOptions) { disk in
                            Text(diskLabel(disk)).tag(String?.some(disk.path))
                        }
                    }
                }
            }
        } header: {
            Text("磁盘信息")
        } footer: {
            if !projectAll && !vm.isLoadingOptions {
                Text("选择需要监控的挂载目录")
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

    private var conditionSection: some View {
        Section {
            if type.isLoginType {
                Stepper(value: $cycle, in: 1...1440) {
                    LabeledContent("时间窗口", value: "\(cycle) 分钟")
                }
                Stepper(value: $failCount, in: 1...999) {
                    LabeledContent("失败次数", value: "\(failCount) 次")
                }
            } else if type.isPercentType {
                LabeledContent("指定时间", value: "5 分钟")
                Stepper(value: $threshold, in: 1...100) {
                    LabeledContent("平均使用率超过", value: "\(threshold)%")
                }
            } else if type.isDisk {
                Picker("监测类型", selection: $diskMonitorKind) {
                    Text("占用磁盘").tag(1)
                    Text("占用百分比").tag(2)
                }
                .pickerStyle(.segmented)
                Stepper(value: $threshold, in: 1...100) {
                    LabeledContent("使用超过", value: "\(threshold)%")
                }
            } else if !type.isSimpleNotice {
                Stepper(value: $cycle, in: 1...90) {
                    LabeledContent("剩余天数", value: "\(cycle) 天")
                }
            }
            Stepper(value: $sendCount, in: 1...99) {
                LabeledContent("告警次数", value: "\(sendCount) 次")
            }
        } header: {
            Text("触发条件")
        } footer: {
            Text(conditionFooter)
        }
    }

    private var conditionFooter: String {
        switch type {
        case .sshLogin, .panelLogin:
            return "窗口时间内登录失败达到次数即触发告警"
        case .cpu, .memory, .load:
            return "时间窗口固定为监控采集间隔 5 分钟，平均使用率超过阈值即触发"
        case .disk:
            return "按监测类型统计磁盘使用，超过阈值即触发"
        case .panelUpdate:
            return "面板有新版本发布时通知"
        default:
            return "证书 / 网站 / 密码到期前，每天检查并按告警次数发送"
        }
    }

    // MARK: - IP 白名单（登录异常类型）

    private var whitelistSection: some View {
        Section {
            TextEditor(text: $whitelist)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 88)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            SectionLabel(title: "IP 白名单", systemImage: "checkmark.shield")
        } footer: {
            Text("白名单内的 IP 登录失败不会触发告警，每行一个，支持 IP 或 CIDR 网段")
        }
    }

    // MARK: - 告警方式

    private var methodSection: some View {
        Section {
            if availableConfigs.isEmpty {
                Label("请先在「设置」中配置发送方式", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Picker("发送至", selection: $sendMethodAll) {
                    Text("所有").tag(true)
                    Text("指定").tag(false)
                }
                .pickerStyle(.segmented)

                if !sendMethodAll {
                    Picker("发送方式", selection: $selectedConfigID) {
                        Text("请选择").tag(Int?.none)
                        ForEach(availableConfigs) { config in
                            Text(config.sendConfig.displayName ?? (config.type ?? "未知")).tag(Int?.some(config.id))
                        }
                    }
                }
            }
        } header: {
            Text("告警方式")
        } footer: {
            Text(availableConfigs.isEmpty ? "告警需要至少一个可用的发送方式" : "触发告警时通过所选方式通知")
        }
    }

    // MARK: - 状态（仅编辑）

    private var statusSection: some View {
        Section {
            Toggle("启用告警", isOn: $enabled)
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
            return "面板密码到期告警"
        case .cpu:
            return "CPU 占用过高告警"
        case .memory:
            return "内存占用过高告警"
        case .load:
            return "负载占用过高告警"
        case .disk:
            if projectAll { return "磁盘占用过高告警" }
            guard let path = selectedDiskPath else { return nil }
            return "挂载目录「\(path)」的磁盘占用过高告警"
        case .sshLogin:
            return "SSH 登录异常告警"
        case .panelLogin:
            return "面板登录异常告警"
        case .ssl:
            if projectAll { return "所有网站证书到期告警" }
            guard let id = selectedProjectID else { return nil }
            return "网站「 \(projectName(id: id)) 」证书到期告警"
        case .siteEndTime:
            if projectAll { return "所有网站到期告警" }
            guard let id = selectedProjectID else { return nil }
            return "网站「 \(projectName(id: id)) 」到期告警"
        case .panelUpdate:
            return "面板新版本提醒"
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
