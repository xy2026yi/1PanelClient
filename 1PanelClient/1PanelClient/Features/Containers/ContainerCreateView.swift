//
//  ContainerCreateView.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 创建容器

/// 表单本体在 ContainerWizardForm（与编辑容器共用，保证两表单一致）；
/// 本视图只负责创建流的任务进度与收尾
struct ContainerCreateView: View {
    @ObservedObject var vm: ContainersViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ContainerCreateDraft()

    /// 向导分页：0 基础 1 端口存储 2 高级（默认收起）
    @State private var wizardPage = 0
    @State private var advancedEnabled = false

    /// 创建任务进度（logs/tasks/read 轮询，复用 TaskProgressView）
    @State private var showCreateProgress = false
    @State private var createTaskID = ""
    @State private var createTaskFinished = false

    var body: some View {
        ContainerWizardForm(
            draft: $draft,
            vm: vm,
            wizardPage: $wizardPage,
            advancedEnabled: $advancedEnabled,
            primaryTitle: L10n.t("创建"),
            isBusy: vm.containerOperating,
            primaryDisabled: draft.name.isEmpty || draft.image.isEmpty,
            onPrimary: {
                Task {
                    if let taskID = await vm.createContainer(draft: draft) {
                        createTaskID = taskID
                        showCreateProgress = true
                    }
                }
            })
        .navigationTitle(L10n.t("创建容器"))
        .navigationBarTitleDisplayMode(.inline)
        .formWidthLimit()
        .task { await vm.loadCreateOptions() }
        .navigationDestination(isPresented: $showCreateProgress) {
            TaskProgressView(taskID: createTaskID,
                             title: L10n.f("创建容器 %@", draft.name)) { isDone in
                createTaskFinished = true
                // 返回 true：进度页自行 dismiss，onDisappear 收向导
                return true
            }
            .onDisappear {
                if createTaskFinished { dismiss() }
            }
        }
        .toastOverlay(message: $vm.toastMessage)
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: { Text(vm.alertMessage) }
    }
}
