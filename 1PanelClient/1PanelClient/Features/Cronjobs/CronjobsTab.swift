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
    @State private var showCreateSheet = false

    init(manager: ServerManager) {
        self.manager = manager
        let server = manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: "")
        _vm = StateObject(wrappedValue: CronjobsViewModel(server: server))
    }

    var body: some View {
        rootContent
            .task { await vm.refresh() }
            .alert(vm.alertMessage, isPresented: $vm.showAlert) {
                Button("好", role: .cancel) {}
            }
            .toastOverlay(message: $vm.toastMessage)
    }

    /// 列表根内容（不含 NavigationStack），供 ManageTab 嵌入复用
    var rootContent: some View {
        Group {
            if vm.isLoading && vm.cronjobs.isEmpty {
                ProgressView("加载中…")
            } else if let err = vm.errorMessage, !err.isEmpty, vm.cronjobs.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(err)
                } actions: {
                    Button("重试") {
                        Task { await vm.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if vm.cronjobs.isEmpty {
                ContentUnavailableView(
                    "暂无计划任务",
                    systemImage: "clock.badge.checkmark",
                    description: Text("点击右上角创建第一个任务")
                )
            } else {
                cronjobList
            }
        }
        .navigationTitle("计划任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ScriptLibraryView(server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
                } label: {
                    Image(systemName: "books.vertical")
                }
                .accessibilityLabel("脚本库")
            }
        }
        .navigationDestination(for: Cronjob.self) { job in
            CronjobDetailView(job: job, vm: vm, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
        .overlay(alignment: .bottomTrailing) {
            FloatingActionButton(action: {
                showCreateSheet = true
            })
            .accessibilityLabel("创建计划任务")
        }
        .navigationDestination(isPresented: $showCreateSheet) {
            CreateCronjobView(vm: vm, server: manager.current ?? ServerConfig(name: "", baseURL: "", apiKey: ""))
        }
    }

    private var cronjobList: some View {
        List {
            ForEach(vm.cronjobs) { job in
                NavigationLink(value: job) {
                    CronjobRow(job: job)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        Task { await vm.handle(job: job) }
                    } label: {
                        Label("执行", systemImage: "play.fill")
                    }
                    .tint(.blue)

                    Button(role: .destructive) {
                        vm.pendingDeleteJob = job
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await vm.refresh()
        }
        .alert("删除任务", isPresented: Binding(
            get: { vm.pendingDeleteJob != nil },
            set: { if !$0 { vm.pendingDeleteJob = nil } }
        )) {
            Button("取消", role: .cancel) {
                vm.pendingDeleteJob = nil
                vm.deleteCleanData = false
            }
            Button("删除", role: .destructive) {
                if let job = vm.pendingDeleteJob {
                    Task { await vm.delete(job: job) }
                }
            }
        } message: {
            VStack {
                Text("确定删除任务「\(vm.pendingDeleteJob?.name ?? "")」吗？")
                Toggle("同时删除备份文件", isOn: $vm.deleteCleanData)
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
                Text(job.name ?? "未命名")
                    .font(.body.bold())
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusBadge(text: job.jobType.displayName, color: job.jobType.color)
                    StatusBadge(text: job.specDisplay, color: .secondary)
                }

                if let last = job.lastRecordStatus, !last.isEmpty {
                    Text("上次：\(job.lastStatusDisplay)")
                        .font(.caption2)
                        .foregroundStyle(job.lastStatusColor)
                }
            }

            Spacer()

            // 启用/禁用徽标
            if !job.isEnabled {
                StatusBadge(text: "已停用", color: .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

