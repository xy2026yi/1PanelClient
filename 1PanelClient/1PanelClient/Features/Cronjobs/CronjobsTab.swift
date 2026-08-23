//
//  CronjobsTab.swift
//  1PanelClient
//
//  计划任务：列表 / 详情 / 创建 / 手动执行 / 删除 / 执行记录 / 日志
//  基于 doc/计划任务.md
//

import SwiftUI
import Combine

struct CronjobsTab: View {
    @ObservedObject var manager: ServerManager
    @StateObject private var vm: CronjobsViewModel
    @State private var showCreate = false
    @State private var searchText = ""
    @State private var isSearching = false

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: CronjobsViewModel(server: server))
    }

    var body: some View {
        rootContent
            .task { await vm.refresh() }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
        Text(vm.alertMessage)
        }
            .toastOverlay(message: $vm.toastMessage)
    }

    /// 列表根内容（不含 NavigationStack），供 ManageTab 嵌入复用
    var rootContent: some View {
        Group {
            if vm.isLoading && vm.cronjobs.isEmpty {
                LoadingStateView()
            } else if let err = vm.errorMessage, !err.isEmpty, vm.cronjobs.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("加载失败"), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button(L10n.t("重试")) {
                        Task { await vm.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if vm.cronjobs.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无计划任务"),
                    systemImage: "clock.badge.checkmark",
                    description: Text(L10n.t("点击右上角创建第一个任务"))
                )
            } else {
                cronjobList
            }
        }
        .searchIconMode(
            text: $searchText,
            isSearching: $isSearching,
            title: L10n.t("计划任务"),
            prompt: L10n.t("搜索脚本名")
        )
        .navigationTitle(L10n.t("计划任务"))
        .navigationBarTitleDisplayMode(.inline)
        // 创建菜单：创建任务 + 脚本库合并为一个 + 入口，右上角只留「+菜单 + 搜索」两键
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showCreate = true
                    } label: {
                        Label(L10n.t("创建计划任务"), systemImage: "plus")
                    }
                    Divider()
                    NavigationLink {
                        ScriptLibraryView(server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
                    } label: {
                        Label(L10n.t("脚本库"), systemImage: "books.vertical")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("创建计划任务"))
            }
        }
        .navigationDestination(for: Cronjob.self) { job in
            CronjobDetailView(job: job, vm: vm, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
        .navigationDestination(isPresented: $showCreate) {
            CreateCronjobView(vm: vm, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
    }

    /// 搜索过滤：按任务名（名称可能为空，按空串处理）
    private var filteredCronjobs: [Cronjob] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return vm.cronjobs }
        return vm.cronjobs.filter { ($0.name ?? "").localizedCaseInsensitiveContains(keyword) }
    }

    private var cronjobList: some View {
        List {
            ForEach(filteredCronjobs) { job in
                NavigationLink(value: job) {
                    CronjobRow(job: job)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        Task { await vm.handle(job: job) }
                    } label: {
                        Label(L10n.t("执行"), systemImage: "play.fill")
                    }
                    .tint(.blue)

                    Button(role: .destructive) {
                        vm.pendingDeleteJob = job
                    } label: {
                        Label(L10n.t("删除"), systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh()
        }
        .sheet(item: $vm.pendingDeleteJob) { job in
            TextInputConfirmSheet(
                title: L10n.t("删除任务"),
                message: L10n.f("此操作不可恢复。请输入任务名称「%@」以确认删除。", job.name ?? ""),
                expectedText: job.name ?? "",
                fieldLabel: L10n.t("确认名称"),
                fieldPlaceholder: L10n.t("任务名称")
            ) {
                Task { await vm.delete(job: job) }
            } options: {
                Section(L10n.t("选项")) {
                    Toggle(L10n.t("同时删除备份文件"), isOn: $vm.deleteCleanData)
                }
            }
        }
    }
}

// MARK: - 任务列表项

struct CronjobRow: View {
    let job: Cronjob

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: job.jobType.icon, color: job.jobType.color)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.name ?? L10n.t("未命名"))
                    .font(.body.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusBadge(text: job.jobType.displayName, color: job.jobType.color)
                    StatusBadge(text: job.specDisplay, color: .secondary)
                }

                if let last = job.lastRecordStatus, !last.isEmpty {
                    Text(L10n.f("上次：%@", job.lastStatusDisplay))
                        .font(.caption2)
                        .foregroundStyle(job.lastStatusColor)
                }
            }

            Spacer()

            // 启用/禁用徽标
            if !job.isEnabled {
                StatusBadge(text: L10n.t("已停用"), color: .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

