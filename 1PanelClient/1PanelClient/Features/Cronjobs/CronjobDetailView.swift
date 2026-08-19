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
    @State private var isLoadingEditInfo = false
    @State private var showDeleteSheet = false
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
                if let script = currentJob.script, !script.isEmpty {
                    Section {
                        Text(script)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } header: { Text(L10n.t("脚本内容")) }
                }
            case .app:
                Section(L10n.t("备份内容")) {
                    InfoRow(L10n.t("备份对象"), value: currentJob.appID == "all" ? L10n.t("全部应用") : (currentJob.appID ?? "—"))
                }
            case .website:
                Section(L10n.t("备份内容")) {
                    InfoRow(L10n.t("备份对象"), value: currentJob.website == "all" ? L10n.t("全部网站") : (currentJob.website ?? "—"))
                }
            case .database:
                Section(L10n.t("备份内容")) {
                    InfoRow(L10n.t("数据库类型"), value: currentJob.dbTypeDisplay)
                    InfoRow(L10n.t("备份对象"), value: currentJob.dbName == "all" ? L10n.t("全部数据库") : (currentJob.dbName ?? "—"))
                    if currentJob.dbTypeDisplay == "MySQL" || currentJob.dbTypeDisplay == "MariaDB" {
                        InfoRow(L10n.t("备份参数"), value: currentJob.dbBackupParamsDisplay)
                    }
                }
            case .snapshot:
                Section(L10n.t("备份内容")) {
                    InfoRow(L10n.t("类型"), value: L10n.t("系统快照"))
                }
            case .clean, .ntp, .syncIpGroup:
                // 缓存清理 / 同步服务器时间 / 同步 WAF IP 组：无类型特定详情
                EmptyView()
            }

            // 操作
            Section {
                Button {
                    Task { await vm.handle(job: currentJob) }
                } label: {
                    Label(L10n.t("立即执行"), systemImage: "play.fill")
                }
                Button {
                    Task { await vm.updateStatus(job: currentJob, enabled: !currentJob.isEnabled) }
                } label: {
                    Label(currentJob.isEnabled ? L10n.t("停用任务") : L10n.t("启用任务"),
                          systemImage: currentJob.isEnabled ? "pause.fill" : "checkmark.circle.fill")
                }
                NavigationLink {
                    CronjobRecordsView(job: currentJob, vm: vm)
                } label: {
                    Label(L10n.t("执行记录"), systemImage: "list.bullet.rectangle")
                }
                Button {
                    Task { await loadEditInfo() }
                } label: {
                    HStack {
                        Label(L10n.t("编辑任务"), systemImage: "pencil")
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
                    showDeleteSheet = true
                } label: {
                    Label(L10n.t("删除任务"), systemImage: "trash")
                }
            } header: {
                Text(L10n.t("危险操作"))
            } footer: {
                Text(L10n.t("删除后不可恢复，可选择是否同时删除已生成的备份文件"))
            }
        }
        .navigationTitle(currentJob.name ?? L10n.t("任务详情"))
        .navigationBarTitleDisplayMode(.inline)
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
                Section(L10n.t("选项")) {
                    Toggle(L10n.t("同时删除备份文件"), isOn: $deleteCleanDataOption)
                }
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

