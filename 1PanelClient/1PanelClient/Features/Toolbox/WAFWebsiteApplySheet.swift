//
//  WAFWebsiteApplySheet.swift
//  1PanelClient
//
//  WAF「应用到网站」网站多选弹层（默认规则应用 / CC 频率限制应用共用）
//

import SwiftUI

// MARK: - 应用到网站（网站多选弹层）

/// 「应用到网站」网站多选弹层：多选网站（含全选，全部网站 = 传入所有网站 ID，
/// 与面板 Web 端一致），确认后执行 apply 闭包，成功回调 onApplied 并自动关闭，
/// 失败在弹层内提示。默认规则应用（rule/common/apply）与 CC 频率限制应用
///（rule/cc，applyWebsite=true + websites）共用
struct WAFWebsiteApplySheet: View {
    let server: ServerConfig
    let onApplied: () -> Void
    let apply: (_ websites: [Int]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var websites: [WAFWebsiteItem] = []
    @State private var selected: Set<Int> = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isApplying = false
    @State private var errorMessage: String?

    private let client: APIClient

    init(server: ServerConfig, onApplied: @escaping () -> Void,
         apply: @escaping (_ websites: [Int]) async throws -> Void) {
        self.server = server
        self.onApplied = onApplied
        self.apply = apply
        self.client = APIClient.shared(for: server)
    }

    private var allSelected: Bool {
        !websites.isEmpty && selected.count == websites.count
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    LoadingStateView()
                        .listRowBackground(Color.clear)
                } else if let err = loadError {
                    LoadErrorStateView(message: err) {
                        Task { await loadWebsites() }
                    }
                    .listRowBackground(Color.clear)
                } else if websites.isEmpty {
                    ContentUnavailableView(
                        L10n.t("暂无网站"),
                        systemImage: "globe",
                        description: Text(L10n.t("安装 OpenResty 并创建网站后才能应用规则"))
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        Button {
                            if allSelected {
                                selected.removeAll()
                            } else {
                                selected = Set(websites.map(\.id))
                            }
                        } label: {
                            HStack {
                                Text(allSelected ? L10n.t("取消全选") : L10n.t("全选"))
                                Spacer()
                                if allSelected {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    } footer: {
                        Text(L10n.t("全部网站即传入所有网站，与面板 Web 端一致"))
                    }

                    Section {
                        ForEach(websites) { site in
                            Button {
                                if selected.contains(site.id) {
                                    selected.remove(site.id)
                                } else {
                                    selected.insert(site.id)
                                }
                            } label: {
                                HStack {
                                    Text(site.primaryDomain ?? site.alias ?? "#\(site.id)")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selected.contains(site.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(L10n.t("选择网站"))
                    }
                }
            }
            .navigationTitle(L10n.t("应用到网站"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await applySelection() }
                    } label: {
                        if isApplying {
                            ProgressView()
                        } else {
                            Text(L10n.t("应用规则"))
                        }
                    }
                    .disabled(selected.isEmpty || isApplying)
                }
            }
        }
        .task { await loadWebsites() }
        .alert(L10n.t("提示"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.t("好的"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadWebsites() async {
        isLoading = true
        defer { isLoading = false }
        do {
            websites = try await fetchAllWAFWebsites(client: client)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func applySelection() async {
        isApplying = true
        defer { isApplying = false }
        do {
            try await apply(Array(selected))
            onApplied()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}


