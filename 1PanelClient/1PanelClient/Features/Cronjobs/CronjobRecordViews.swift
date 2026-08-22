//
//  CronjobRecordViews.swift
//  1PanelClient
//

import SwiftUI

// MARK: - 执行记录

struct CronjobRecordsView: View {
    let job: Cronjob
    @ObservedObject var vm: CronjobsViewModel
    @State private var selectedRecord: CronjobRecord?

    var body: some View {
        List {
            if vm.isLoadingRecords && vm.records.isEmpty {
                LoadingStateView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } else if vm.records.isEmpty {
                ContentUnavailableView(
                    L10n.t("暂无执行记录"),
                    systemImage: "list.bullet.rectangle",
                    description: Text(L10n.t("点击任务详情中的「立即执行」生成第一条记录"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(vm.records) { record in
                    Button {
                        selectedRecord = record
                    } label: {
                        CronjobRecordRow(record: record)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(L10n.t("执行记录"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadRecords(jobId: job.id) }
        .refreshable { await vm.loadRecords(jobId: job.id) }
        .navigationDestination(isPresented: Binding(
            get: { selectedRecord != nil },
            set: { if !$0 { selectedRecord = nil } }
        )) {
            if let record = selectedRecord, let taskID = record.taskID {
                CronjobLogView(taskID: taskID, record: record, vm: vm)
            }
        }
    }
}

struct CronjobRecordRow: View {
    let record: CronjobRecord

    var body: some View {
        HStack(spacing: 12) {
                StatusDot(color: record.statusColor, diameter: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.startTime ?? "—")
                        .font(.subheadline.bold())
                    Spacer()
                    Text(record.statusDisplay)
                        .font(.caption.bold())
                        .foregroundStyle(record.statusColor)
                }
                HStack(spacing: 8) {
                    Text(L10n.f("耗时 %@", record.durationDisplay))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let msg = record.message, !msg.isEmpty {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 日志查看

struct CronjobLogView: View {
    let taskID: String
    let record: CronjobRecord
    @ObservedObject var vm: CronjobsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if vm.isLoadingLog && vm.logLines.isEmpty {
                    LoadingStateView()
                        .padding()
                } else if let err = vm.logError {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .padding()
                } else if vm.logLines.isEmpty {
                    Text(L10n.t("暂无日志"))
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(Array(vm.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 2)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
        .navigationTitle(L10n.t("执行日志"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadLog(taskID: taskID) }
    }
}

