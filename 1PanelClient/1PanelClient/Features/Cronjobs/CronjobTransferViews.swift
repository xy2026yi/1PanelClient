//
//  CronjobTransferViews.swift
//  1PanelClient
//
//  计划任务导入导出（cronjobs/export · import，logs/可选增加-2 抓包 2026-09-16）：
//  导出 = 勾选任务 → export {ids} → 落地 1panel-cronjob-*.json → 系统分享；
//  导入 = 选 json 文件 → 解析并列出任务（名称/类型/周期/保留份数）→ 勾选 import
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 导出

/// 导出计划任务：任务勾选列表 + 导出按钮（导出后出现分享行）
struct CronjobExportView: View {
    let server: ServerConfig
    /// 任务列表数据源（复用列表页已加载的 cronjobs）
    let cronjobs: [Cronjob]
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<Int>
    @State private var isExporting = false
    /// 导出成功后的本地文件（出现「分享 / 另存为」）
    @State private var exportedURL: URL?
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, cronjobs: [Cronjob], onDone: @escaping () -> Void = {}) {
        self.server = server
        self.cronjobs = cronjobs
        self.onDone = onDone
        self.client = APIClient.shared(for: server)
        // 默认全选（导出通常要整包迁移，可再手动取消）
        _selectedIDs = State(initialValue: Set(cronjobs.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Form {
                taskListSection
                submitSection
            }
            .navigationTitle(L10n.t("导出计划任务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("关闭")) { dismiss() }
                        .disabled(isExporting)
                }
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
        .interactiveDismissDisabled(isExporting)
    }

    /// 任务勾选列表（默认全选）
    private var taskListSection: some View {
        Section {
            ForEach(cronjobs) { job in
                exportRow(job)
            }
        } header: {
            SectionLabel(title: L10n.f("计划任务（%ld）", cronjobs.count), systemImage: "clock.badge.checkmark")
        } footer: {
            exportFooter
        }
    }

    private func exportRow(_ job: Cronjob) -> some View {
        Button {
            if selectedIDs.contains(job.id) {
                selectedIDs.remove(job.id)
            } else {
                selectedIDs.insert(job.id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedIDs.contains(job.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(job.id) ? Color.accentColor : Color.secondary)
                CronjobRow(job: job)
            }
        }
        .buttonStyle(.plain)
    }

    /// 导出后出现「分享」入口（文件已写入临时目录）
    @ViewBuilder
    private var exportFooter: some View {
        if let url = exportedURL {
            ShareLink(item: url) {
                Label(
                    L10n.f("分享 %@", url.lastPathComponent),
                    systemImage: "square.and.arrow.up"
                )
            }
        } else {
            Text(L10n.t("勾选要导出的任务，导出为 JSON 文件用于迁移或备份"))
        }
    }

    private var submitSection: some View {
        Section {
            Button {
                Task { await submit() }
            } label: {
                HStack {
                    if isExporting { ProgressView() } else { Text(L10n.t("导出")) }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(selectedIDs.isEmpty || isExporting)
        }
    }

    private func submit() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let items: [CronjobTransferItem] = try await client.send(
                path: APIEndpoint.cronjobsExport.path,
                body: CronjobExportRequest(ids: selectedIDs.sorted()),
                as: [CronjobTransferItem].self)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            // 文件名对齐网页端下载：1panel-cronjob-YYYYMMddHHmmss.json
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMddHHmmss"
            // 先清掉历史导出文件再写新文件（分享用的是本次的 exportedURL）
            cleanupOldExports()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("1panel-cronjob-\(stamp.string(from: Date())).json")
            try data.write(to: url)
            exportedURL = url
            Haptic.success()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// 清理临时目录里历史导出的 cronjob JSON（每次导出只保留最新一份）
    private func cleanupOldExports() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for url in files
        where url.lastPathComponent.hasPrefix("1panel-cronjob-") && url.pathExtension == "json" {
            try? fm.removeItem(at: url)
        }
    }
}

// MARK: - 导入

/// 导入计划任务：选择 JSON 文件 → 解析列出（名称/类型/周期/保留份数）→ 勾选导入
struct CronjobImportView: View {
    let server: ServerConfig
    var onDone: () async -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    @State private var items: [CronjobTransferItem] = []
    @State private var selectedIDs: Set<String> = []
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showError = false

    private let client: APIClient

    init(server: ServerConfig, onDone: @escaping () async -> Void = {}) {
        self.server = server
        self.onDone = onDone
        self.client = APIClient.shared(for: server)
    }

    var body: some View {
        NavigationStack {
            Form {
                if items.isEmpty {
                    Section {
                        Button {
                            showFilePicker = true
                        } label: {
                            Label(L10n.t("选择 JSON 文件"), systemImage: "doc.badge.arrow.up")
                        }
                    } footer: {
                        Text(L10n.t("选择导出的 1panel-cronjob-*.json 文件，解析后勾选要导入的任务"))
                    }
                } else {
                    Section {
                        ForEach(items) { item in
                            Button {
                                if selectedIDs.contains(item.id) {
                                    selectedIDs.remove(item.id)
                                } else {
                                    selectedIDs.insert(item.id)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedIDs.contains(item.id) ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name)
                                            .font(.body.bold())
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            StatusBadge(
                                                text: (CronjobType(rawValue: item.type) ?? .shell).displayName,
                                                color: (CronjobType(rawValue: item.type) ?? .shell).color
                                            )
                                            StatusBadge(text: item.spec, color: .secondary)
                                        }
                                        Text(L10n.f("保留 %ld 份", item.retainCopies))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        SectionLabel(
                            title: L10n.f("文件中的任务（%ld）", items.count),
                            systemImage: "clock.badge.checkmark"
                        )
                    } footer: {
                        Text(L10n.t("保留份数与执行周期将按文件内容创建；同名任务不会被跳过，请自行确认"))
                    }

                    Section {
                        Button {
                            Task { await submit() }
                        } label: {
                            HStack {
                                if isImporting { ProgressView() } else { Text(L10n.t("导入")) }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(selectedIDs.isEmpty || isImporting)
                    }
                }
            }
            .navigationTitle(L10n.t("导入计划任务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("关闭")) { dismiss() }
                        .disabled(isImporting)
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                parseFile(url)
            }
            .alert(L10n.t("提示"), isPresented: $showError) {
                Button(L10n.t("好的"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .bottomSheetDetents([.large])
        .interactiveDismissDisabled(isImporting)
    }

    private func parseFile(_ url: URL) {
        do {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([CronjobTransferItem].self, from: data)
            guard !decoded.isEmpty else {
                errorMessage = L10n.t("文件中没有可导入的任务")
                showError = true
                return
            }
            items = decoded
            selectedIDs = Set(decoded.map(\.id))
        } catch {
            errorMessage = L10n.f("解析失败：%@", error.localizedDescription)
            showError = true
        }
    }

    private func submit() async {
        isImporting = true
        defer { isImporting = false }
        let selected = items.filter { selectedIDs.contains($0.id) }
        do {
            let _: EmptyResponse = try await client.send(
                path: APIEndpoint.cronjobsImport.path,
                body: CronjobImportRequest(cronjobs: selected),
                as: EmptyResponse.self)
            Haptic.success()
            await onDone()
            dismiss()
        } catch {
            guard !APIError.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
