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
            Section("基本信息") {
                InfoRow("名称", value: currentJob.name ?? "—")
                InfoRow("类型", value: currentJob.jobType.displayName)
                InfoRow("执行周期", value: currentJob.specDisplay)
                InfoRow("状态", value: currentJob.isEnabled ? "启用" : "停用")
                InfoRow("保留份数", value: currentJob.retainCopiesDisplay)
                if let r = currentJob.retryTimes, r > 0 {
                    InfoRow("重试次数", value: "\(r) 次")
                }
                if let t = currentJob.timeout, t > 0 {
                    InfoRow("超时", value: "\(t)\(currentJob.timeoutUnit ?? "s")")
                }
            }

            // 类型相关详情
            switch currentJob.jobType {
            case .shell:
                if let user = currentJob.user, !user.isEmpty {
                    Section("执行设置") {
                        InfoRow("执行用户", value: user)
                        if currentJob.inContainer == true {
                            InfoRow("容器", value: currentJob.containerName ?? "—")
                        }
                    }
                }
                if let script = currentJob.script, !script.isEmpty {
                    Section {
                        Text(script)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    } header: { Text("脚本内容") }
                }
            case .app:
                Section("备份内容") {
                    InfoRow("备份对象", value: currentJob.appID == "all" ? "全部应用" : (currentJob.appID ?? "—"))
                }
            case .website:
                Section("备份内容") {
                    InfoRow("备份对象", value: currentJob.website == "all" ? "全部网站" : (currentJob.website ?? "—"))
                }
            case .database:
                Section("备份内容") {
                    InfoRow("数据库类型", value: currentJob.dbTypeDisplay)
                    InfoRow("备份对象", value: currentJob.dbName == "all" ? "全部数据库" : (currentJob.dbName ?? "—"))
                    if currentJob.dbTypeDisplay == "MySQL" || currentJob.dbTypeDisplay == "MariaDB" {
                        InfoRow("备份参数", value: currentJob.dbBackupParamsDisplay)
                    }
                }
            case .snapshot:
                Section("备份内容") {
                    InfoRow("类型", value: "系统快照")
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
                    Label("立即执行", systemImage: "play.fill")
                }
                Button {
                    Task { await vm.updateStatus(job: currentJob, enabled: !currentJob.isEnabled) }
                } label: {
                    Label(currentJob.isEnabled ? "停用任务" : "启用任务",
                          systemImage: currentJob.isEnabled ? "pause.fill" : "checkmark.circle.fill")
                }
                NavigationLink {
                    CronjobRecordsView(job: currentJob, vm: vm)
                } label: {
                    Label("执行记录", systemImage: "list.bullet.rectangle")
                }
                Button {
                    Task { await loadEditInfo() }
                } label: {
                    HStack {
                        Label("编辑任务", systemImage: "pencil")
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
                    Label("删除任务", systemImage: "trash")
                }
            } header: {
                Text("危险操作")
            } footer: {
                Text("删除后不可恢复，可选择是否同时删除已生成的备份文件")
            }
        }
        .navigationTitle(currentJob.name ?? "任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDeleteSheet) {
            TextInputConfirmSheet(
                title: "删除任务",
                message: "此操作不可恢复。请输入任务名称「\(currentJob.name ?? "")」以确认删除。",
                expectedText: currentJob.name ?? "",
                fieldLabel: "确认名称",
                fieldPlaceholder: "任务名称"
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
                Section("选项") {
                    Toggle("同时删除备份文件", isOn: $deleteCleanDataOption)
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

