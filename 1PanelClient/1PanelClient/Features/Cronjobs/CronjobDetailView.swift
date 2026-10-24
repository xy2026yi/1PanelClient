//
//  CronjobDetailView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 任务详情

struct CronjobDetailView: View {
    let job: Cronjob
    @ObservedObject var vm: CronjobsViewModel
    var server: ServerConfig = ServerConfig(name: "", baseURL: "", apiKey: "")
    @Environment(\.dismiss) private var dismiss
    @State private var editingInfo: CronjobInfo?
    @State private var showEditView = false
    @State private var showDeleteSheet = false
    /// 快照任务详情（load/info；仅 snapshot 类型加载，用于展示镜像开关与排除应用）
    @State private var snapshotInfo: CronjobInfo?
    /// 通用详情（load/info；告警设置仅 info 返回，列表模型无这些字段——
    /// 有设置才展示告警分组；Shell 的 path 模式也由它区分脚本路径/内容）
    @State private var detailInfo: CronjobInfo?
    /// 快照详情加载失败（「—」占位不可永久残留，给重试入口）
    @State private var snapshotLoadFailed = false
    /// 删除确认弹窗中的「同时删除备份文件」选项（传入共享 TextInputConfirmSheet）
    @State private var deleteCleanDataOption = false

    /// 从 ViewModel 列表中查找最新的任务数据。
    /// 编辑后 vm.cronjobs 会刷新，此属性返回更新后的版本；
    /// 如果列表中已无此任务（被删除），则回退到原始 job。
    private var currentJob: Cronjob {
        vm.cronjobs.first(where: { $0.id == job.id }) ?? job
    }

    var body: some View {
        List {
            Section(L10n.t("基本信息")) {
                InfoRow(L10n.t("名称"), value: currentJob.name ?? "—")
                InfoRow(L10n.t("类型"), value: currentJob.jobType.displayName)
                InfoRow(L10n.t("执行周期"), value: currentJob.specDisplay)
                InfoRow(L10n.t("状态"), value: currentJob.isEnabled ? L10n.t("启用") : L10n.t("停用"))
                InfoRow(L10n.t("保留份数"), value: currentJob.retainCopiesDisplay)
                if let r = currentJob.retryTimes, r > 0 {
                    InfoRow(L10n.t("重试次数"), value: L10n.f("%ld 次", r))
                }
                if let t = currentJob.timeout, t > 0 {
                    InfoRow(L10n.t("超时"), value: "\(t)\(currentJob.timeoutUnit ?? "s")")
                }
            }

            // 类型相关详情
            switch currentJob.jobType {
            case .shell:
                if let user = currentJob.user, !user.isEmpty {
                    Section(L10n.t("执行设置")) {
                        InfoRow(L10n.t("执行用户"), value: user)
                        if currentJob.inContainer == true {
                            InfoRow(L10n.t("容器"), value: currentJob.containerName ?? "—")
                        }
                    }
                }
                // select（路径选择）模式：script 存的是文件路径，以路径行展示而非内容块
                if scriptModeOfJob == "select" {
                    if let path = currentJob.script, !path.isEmpty {
                        Section {
                            InfoRow(L10n.t("脚本路径"), value: path)
                        }
                    }
                } else if let script = currentJob.script, !script.isEmpty {
                    Section {
                        Text(script)
                            .font(.dataMonospacedCaption)
                            .textSelection(.enabled)
                    } header: { Text(L10n.t("脚本内容")) }
                }
            case .app:
                readonlyTargetsSection(label: L10n.t("备份对象"),
                                       text: backupTargetsText(currentJob.appID,
                                                               allLabel: L10n.t("全部应用")))
            case .website:
                readonlyTargetsSection(label: L10n.t("备份对象"), text: websiteTargetsText)
            case .database:
                Section(L10n.t("备份内容")) {
                    InfoRow(L10n.t("数据库类型"), value: currentJob.dbTypeDisplay)
                    if currentJob.dbTypeDisplay == "MySQL" || currentJob.dbTypeDisplay == "MariaDB" {
                        InfoRow(L10n.t("备份参数"), value: currentJob.dbBackupParamsDisplay)
                    }
                }
                readonlyTargetsSection(label: L10n.t("备份对象"), text: dbTargetsText)
            case .snapshot:
                if snapshotInfo == nil && snapshotLoadFailed {
                    // load/info 失败：给出可重试的错误态，不让「—」占位永久残留
                    Section {
                        LoadErrorStateView(message: L10n.t("快照详情加载失败")) {
                            Task { await loadSnapshotInfo() }
                        }
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section(L10n.t("备份内容")) {
                        InfoRow(L10n.t("类型"), value: L10n.t("系统快照"))
                        InfoRow(L10n.t("备份所有应用镜像"),
                                value: withImageDisplay)
                    }
                    // 排除应用：形态 7.1 只读展示（应用名一行一个，默认 3 行）
                    Section {
                        OutlinedMultiLineField(label: L10n.t("排除应用"),
                                               lines: 3,
                                               text: .constant(excludedAppsText))
                            .disabled(true)
                    }
                }
            case .directory:
                // 文件模式下 sourceDir 是逗号拼接的多路径，按行展示更可读
                Section(L10n.t("备份内容")) {
                    let paths = (currentJob.sourceDir ?? "")
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if paths.count <= 1 {
                        InfoRow(L10n.t("范围"), value: currentJob.sourceDir ?? "—")
                    } else {
                        ForEach(paths, id: \.self) { path in
                            InfoRow(L10n.t("范围"), value: path)
                        }
                    }
                }
            case .log:
                // 备份日志：无类型特定详情
                EmptyView()
            case .curl:
                Section(L10n.t("访问内容")) {
                    InfoRow(L10n.t("URL 地址"), value: currentJob.url ?? "—")
                }
            case .cutWebsiteLog:
                // website 存网站 id 串：与备份网站同款解析（id → primaryDomain）
                readonlyTargetsSection(label: L10n.t("网站"), text: websiteTargetsText)
            case .cleanLog:
                Section(L10n.t("清理内容")) {
                    InfoRow(L10n.t("清理类型"), value: L10n.t("网站日志"))
                }
            case .clean, .ntp, .syncIpGroup:
                // 缓存清理 / 同步服务器时间 / 同步 WAF IP 组：无类型特定详情
                EmptyView()
            }

            // 告警设置（有设置才显示）。判定信号双路：列表响应自带 alertCount
            // （>0 即已设置——关闭告警时 Web 端提交 0；v2.4.0 响应侧不回传
            // hasAlert，抓包 2026-10-22）与 load/info 的告警方式明细（方法 id）
            if let alert = alertDisplay {
                Section(L10n.t("告警")) {
                    InfoRow(L10n.t("告警方式"), value: alertMethodNames(alert.methodIDs))
                    InfoRow(L10n.t("通知条件"), value: alertTriggerLabel(alert.trigger))
                    if let count = alert.count, count > 0 {
                        InfoRow(L10n.t("告警次数"), value: L10n.f("%ld 次", count))
                    }
                }
            }

            // 记录入口（立即执行/结束任务/停用启用/编辑/删除已收进右上角三点菜单）
            Section {
                NavigationLink {
                    CronjobRecordsView(job: currentJob, vm: vm)
                } label: {
                    Label(L10n.t("执行记录"), systemImage: "list.bullet.rectangle")
                }
                if currentJob.jobType.producesBackupRecords {
                    NavigationLink {
                        CronjobBackupRecordsView(job: currentJob)
                    } label: {
                        Label(L10n.t("备份记录"), systemImage: "externaldrive.badge.timemachine")
                    }
                }
            }
        }
        .navigationTitle(currentJob.name ?? L10n.t("任务详情"))
        // 停止/操作错误在当前页提示（此前只在列表页挂载，返回一层才弹）
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage)
        }
        .navigationBarTitleDisplayMode(.inline)
        // 右上角三点菜单：任务操作（立即执行/结束任务/停用启用/编辑/删除）
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await vm.handle(job: currentJob) }
                    } label: {
                        Label(L10n.t("立即执行"), systemImage: "play.fill")
                    }
                    Button {
                        Task { await vm.stop(job: currentJob) }
                    } label: {
                        Label(L10n.t("结束任务"), systemImage: "stop.fill")
                    }
                    Button {
                        Task { await vm.updateStatus(job: currentJob, enabled: !currentJob.isEnabled) }
                    } label: {
                        Label(currentJob.isEnabled ? L10n.t("停用任务") : L10n.t("启用任务"),
                              systemImage: currentJob.isEnabled ? "pause.fill" : "checkmark.circle.fill")
                    }
                    Divider()
                    Button {
                        Task { await loadEditInfo() }
                    } label: {
                        Label(L10n.t("编辑任务"), systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteSheet = true
                    } label: {
                        Label(L10n.t("删除任务"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(L10n.t("更多操作"))
            }
        }
        .sheet(isPresented: $showDeleteSheet) {
            TextInputConfirmSheet(
                title: L10n.t("删除任务"),
                message: L10n.f("此操作不可恢复。请输入任务名称「%@」以确认删除。", currentJob.name ?? ""),
                expectedText: currentJob.name ?? "",
                fieldLabel: L10n.t("确认名称"),
                fieldPlaceholder: L10n.t("任务名称")
            ) {
                Task {
                    // 同步删除选项到 ViewModel（delete 方法内部读取 deleteCleanData）
                    vm.deleteCleanData = deleteCleanDataOption
                    let success = await vm.delete(job: currentJob)
                    if success {
                        dismiss()
                    }
                }
            } options: {
                // 同时删除备份文件仅备份类任务展示（与「备份记录」入口同判据）
                if currentJob.jobType.producesBackupRecords {
                    Section(L10n.t("选项")) {
                        Toggle(L10n.t("同时删除备份文件"), isOn: $deleteCleanDataOption)
                    }
                }
            }
        }
        .toastOverlay(message: $vm.toastMessage)
        .navigationDestination(isPresented: Binding(
            get: { showEditView },
            set: { showing in
                showEditView = showing
                // 编辑返回后作废已加载的详情缓存并重拉：update 只刷新列表，
                // 告警方式明细/快照规则等 info 侧数据不重取会保持旧值
                if !showing {
                    editingInfo = nil
                    detailInfo = nil
                    snapshotInfo = nil
                    Task { await reloadInfoForCurrentType() }
                }
            }
        )) {
            if let info = editingInfo {
                CreateCronjobView(vm: vm, server: server, editingJob: info)
            }
        }
        // 快照任务：详情接口含镜像开关/排除应用（列表模型无这些字段），
        // 与已装应用列表并行加载（排除应用按 id 解析应用名）；
        // 备份网站/切割网站日志：拉网站简表解析 id → primaryDomain；
        // 备份数据库：按任务类型拉实例列表解析 id → 库名
        .task(id: currentJob.id) { await reloadInfoForCurrentType() }
    }

    /// 按类型补拉 info：快照详情（镜像/排除应用）、Shell 脚本来源模式与告警
    /// 明细。其余类型仅在有告警信号（列表 alertCount>0）时拉 info，无信号跳过
    /// 省一次请求（网站/数据库类型只拉名称解析表）
    private func reloadInfoForCurrentType() async {
        switch currentJob.jobType {
        case .snapshot:
            guard snapshotInfo == nil else { return }
            await loadSnapshotInfo()
        case .website, .cutWebsiteLog:
            await vm.loadWebsiteOptions()
        case .database:
            await vm.loadDBItems(dbType: currentJob.dbType ?? "mysql")
        case .shell:
            guard detailInfo == nil else { return }
            await loadDetailInfo()
        default:
            if currentJob.hasAlertConfigured, detailInfo == nil {
                await loadDetailInfo()
            }
        }
    }

    /// 通用详情加载：load/info + 告警方式名称表（id → 标题）并行
    private func loadDetailInfo() async {
        async let methods: Void = vm.loadAlertMethodOptions()
        let info = await vm.loadCronjobInfo(id: currentJob.id)
        await methods
        detailInfo = info
    }

    /// Shell 脚本来源模式（info 优先，列表模型兜底；枚举 input/library/select，
    /// 未知回落 input）
    private var scriptModeOfJob: String {
        let mode = detailInfo?.scriptMode ?? currentJob.scriptMode
        return (mode == "library" || mode == "select") ? mode! : "input"
    }

    /// 告警展示数据：info 优先（含告警方式明细），列表信号兜底（alertCount>0，
    /// 进页即可显，无需等 info；两路 trigger 归一同口径）
    private var alertDisplay: (methodIDs: Set<Int>, trigger: String, count: Int?)? {
        if let info = detailInfo {
            if info.hasAlert == true || !info.alertMethodIDSet.isEmpty || (info.alertCount ?? 0) > 0 {
                return (info.alertMethodIDSet, info.alertTriggerModeValue, info.alertCount)
            }
        }
        guard currentJob.hasAlertConfigured else { return nil }
        return ([], currentJob.alertTriggerModeValue, currentJob.alertCount)
    }

    /// 告警方式名称（id → 方式名；config.displayName 优先——title 是内部键
    /// 如 xpack.alert.bark，回退链与告警方式选择器同款：displayName → title → 未知）
    private func alertMethodNames(_ ids: Set<Int>) -> String {
        guard !ids.isEmpty else { return L10n.t("未设置") }
        return ids
            .map { id in
                guard let method = vm.alertMethods.first(where: { $0.id == id }) else {
                    return "#\(id)"
                }
                return method.sendConfig.displayName ?? method.title ?? L10n.t("未知")
            }
            .joined(separator: ", ")
    }

    /// 通知条件文案（与创建表单三选同款）
    private func alertTriggerLabel(_ mode: String) -> String {
        switch mode {
        case "success": return L10n.t("仅成功")
        case "both": return L10n.t("成功或失败")
        default: return L10n.t("仅失败")
        }
    }

    /// 备份对象/网站：形态 7.1 只读展示（一项一行，默认 1 行自动增高；
    /// 与快照「排除应用」同款只读描边框）
    private func readonlyTargetsSection(label: String, text: String) -> some View {
        Section {
            OutlinedMultiLineField(label: label,
                                   lines: 1,
                                   text: .constant(text))
                .disabled(true)
        }
    }

    /// 备份对象展示文本："all" → 全部标签，逗号串 → 一行一项，空 → —；
    /// resolve 非空时逐项解析（如 id → primaryDomain），解析失败回落原始值
    private func backupTargetsText(_ raw: String?, allLabel: String,
                                    resolve: ((String) -> String?)? = nil) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        if raw == "all" { return allLabel }
        let items = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if items.isEmpty { return "—" }
        guard let resolve else { return items.joined(separator: "\n") }
        return items.map { resolve($0) ?? $0 }.joined(separator: "\n")
    }

    /// 备份对象（网站）：website 存网站 id 串，解析为 primaryDomain
    /// （缺失回落 alias，再回落原始 id；列表异步加载完成后自动刷新）
    private var websiteTargetsText: String {
        backupTargetsText(currentJob.website, allLabel: L10n.t("全部网站")) { id in
            guard let site = vm.websiteOptions.first(where: { String($0.id) == id }) else {
                return nil
            }
            return site.primaryDomain ?? site.alias
        }
    }

    /// 备份对象（数据库）：dbName 存数据库 id 串，解析为实例列表的 name
    /// （dbItems 按任务类型异步加载，完成后自动刷新）
    private var dbTargetsText: String {
        backupTargetsText(currentJob.dbName, allLabel: L10n.t("全部数据库")) { id in
            vm.dbItems.first(where: { String($0.id) == id })?.name
        }
    }

    /// 备份所有应用镜像状态：加载中显示 —，启用/关闭随 load/info
    private var withImageDisplay: String {
        guard let info = snapshotInfo else { return "—" }
        let on = info.snapshotRule?.withImage ?? info.withImage ?? false
        return on ? L10n.t("启用") : L10n.t("关闭")
    }

    /// 排除应用只读文本：加载中留空，id 解析应用名（未知回落 #id），空为「无」
    private var excludedAppsText: String {
        guard let info = snapshotInfo else { return "" }
        let ids = info.snapshotRule?.ignoreAppIDs ?? info.ignoreAppIDs ?? []
        guard !ids.isEmpty else { return L10n.t("无") }
        return ids.map { id in
            vm.installedApps.first { $0.id == id }?.name ?? "#\(id)"
        }.joined(separator: "\n")
    }

    /// 加载编辑所需的任务详情，加载成功后跳转到编辑表单
    /// （失败由 loadCronjobInfo 内部弹 alert）
    private func loadEditInfo() async {
        if let info = await vm.loadCronjobInfo(id: job.id) {
            editingInfo = info
            showEditView = true
        }
    }

    /// 快照详情加载：load/info + 排除应用名解析所需的已装应用（轻量拉取，
    /// 不随 createOptions 全套请求）；两者互不依赖并行发出；失败置位供错误态重试
    private func loadSnapshotInfo() async {
        async let apps: Void = vm.loadInstalledApps()
        let info = await vm.loadCronjobInfo(id: currentJob.id)
        await apps
        if let info {
            snapshotInfo = info
            snapshotLoadFailed = false
        } else {
            snapshotLoadFailed = true
        }
    }
}

