//
//  CronjobBackupRecordViews.swift
//  1PanelClient
//
//  计划任务详情 → 备份记录（POST /backups/record/search/bycronjob，字段同 record/search）
//  含备份记录/快照共用的描述修改 Sheet（description/update，≤256 字符）
//

import SwiftUI

// MARK: - 备份记录（按计划任务过滤）

struct CronjobBackupRecordsView: View {
    /// 数据态与网络动作（@Observable 样板：导航/弹窗呈现态留在视图）
    @State private var vm: CronjobBackupRecordsViewModel

    @State private var editingRecord: BackupRecord?

    init(job: Cronjob) {
        _vm = State(initialValue: CronjobBackupRecordsViewModel(
            job: job,
            client: APIClient.shared(for: ServerManager.shared.current
                                      ?? ServerConfig(name: "", baseURL: "", apiKey: ""))))
    }

    var body: some View {
        List {
            if vm.isLoading {
                HStack { Spacer(); LoadingStateView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else if let err = vm.loadError {
                LoadErrorStateView(message: err) {
                    Task { await vm.load() }
                }
                .listRowBackground(Color.clear)
            } else if vm.records.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无备份记录"),
                    systemImage: "externaldrive.badge.timemachine",
                    description: Text(L10n.t("该任务的备份完成后会显示在这里"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(vm.records) { record in
                    recordRow(record)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.t("备份记录"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .refreshable { await vm.load() }
        .toastOverlay(message: $vm.toastMessage)
        .sheet(item: $editingRecord) { record in
            DescriptionEditSheet(
                title: L10n.t("修改描述"),
                initial: record.description ?? ""
            ) { newText in
                await vm.submitDescription(record, newText)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func recordRow(_ record: BackupRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.fileName ?? "—")
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(record.displayCreatedAt)
                if let status = record.status, !status.isEmpty {
                    Text(status)
                        .foregroundStyle(record.statusColor)
                }
                if let type = record.accountType, !type.isEmpty {
                    Text(type)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let desc = record.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                editingRecord = record
            } label: {
                Label(L10n.t("修改描述"), systemImage: "pencil.line")
            }
            .tint(.teal)
        }
    }
}

// MARK: - 描述修改 Sheet（备份记录 / 快照共用）

/// 返回 nil = 保存成功（自动收起）；非 nil = 失败原因（留在 Sheet 内展示）
struct DescriptionEditSheet: View {
    let title: String
    let initial: String
    let onSubmit: (String) async -> String?

    @State private var text: String
    @State private var isSubmitting = false
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    private let maxLength = 256

    init(title: String, initial: String, onSubmit: @escaping (String) async -> String?) {
        self.title = title
        self.initial = initial
        self.onSubmit = onSubmit
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OutlinedTextField(label: L10n.t("描述"),
                                      prompt: L10n.t("选填"),
                                      text: $text)
                } footer: {
                    Text(errorText ?? L10n.f("%ld / 256", text.count))
                        .foregroundStyle(errorText == nil ? Color.secondary : Color.red)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存")) {
                        isSubmitting = true
                        errorText = nil
                        Task {
                            let result = await onSubmit(text.trimmingCharacters(in: .whitespacesAndNewlines))
                            isSubmitting = false
                            if result == nil {
                                dismiss()
                            } else {
                                errorText = result
                            }
                        }
                    }
                    .disabled(isSubmitting || text == initial)
                }
            }
            .onChange(of: text) { _, newValue in
                if newValue.count > maxLength {
                    text = String(newValue.prefix(maxLength))
                }
            }
        }
    }
}
